-- | Defunctionalization of typed, monomorphic Futhark programs without modules.
module Futhark.Internalise.Defunctionalise (transformProg) where

import Control.Monad.Identity
import Control.Monad.Reader
import Control.Monad.State
import Data.Bifunctor
import Data.Bitraversable
import Data.Foldable
import Data.List (partition, sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as M
import Data.Maybe
import Data.Set qualified as S
import Futhark.IR.Pretty ()
import Futhark.MonadFreshNames
import Futhark.Util (mapAccumLM)
import Language.Futhark
import Language.Futhark.Traversals
import Language.Futhark.TypeChecker.Types (Subst (..), applySubst)

-- | A static value stores additional information about the result of
-- defunctionalization of an expression, aside from the residual expression.
data StaticVal
  = Dynamic PatType
  | -- | The Env is the lexical closure of the lambda.
    LambdaSV Pat StructRetType Exp Env
  | RecordSV [(Name, StaticVal)]
  | -- | The constructor that is actually present, plus
    -- the others that are not.
    SumSV Name [StaticVal] [(Name, [PatType])]
  | -- | The pair is the StaticVal and residual expression of this
    -- function as a whole, while the second StaticVal is its
    -- body. (Don't trust this too much, my understanding may have
    -- holes.)
    DynamicFun (Exp, StaticVal) StaticVal
  | IntrinsicSV
  | HoleSV PatType SrcLoc
  deriving (Show)

-- | The type is Just if this is a polymorphic binding that must be
-- instantiated.
data Binding = Binding (Maybe ([VName], StructType)) StaticVal
  deriving (Show)

bindingSV :: Binding -> StaticVal
bindingSV (Binding _ sv) = sv

-- | Environment mapping variable names to their associated static
-- value.
type Env = M.Map VName Binding

localEnv :: Env -> DefM a -> DefM a
localEnv env = local $ second (env <>)

-- Even when using a "new" environment (for evaluating closures) we
-- still ram the global environment of DynamicFuns in there.
localNewEnv :: Env -> DefM a -> DefM a
localNewEnv env = local $ \(globals, old_env) ->
  (globals, M.filterWithKey (\k _ -> k `S.member` globals) old_env <> env)

askEnv :: DefM Env
askEnv = asks snd

areGlobal :: [VName] -> DefM a -> DefM a
areGlobal vs = local $ first (S.fromList vs <>)

replaceTypeSizes ::
  M.Map VName SizeSubst ->
  TypeBase Size als ->
  TypeBase Size als
replaceTypeSizes substs = first onDim
  where
    onDim (NamedSize v) =
      case M.lookup (qualLeaf v) substs of
        Just (SubstNamed v') -> NamedSize v'
        Just (SubstConst d) -> ConstSize d
        Nothing -> NamedSize v
    onDim d = d

replaceStaticValSizes ::
  S.Set VName ->
  M.Map VName SizeSubst ->
  StaticVal ->
  StaticVal
replaceStaticValSizes globals orig_substs sv =
  case sv of
    _ | M.null orig_substs -> sv
    LambdaSV param (RetType t_dims t) e closure_env ->
      let substs =
            foldl' (flip M.delete) orig_substs $
              S.fromList (M.keys closure_env)
       in LambdaSV
            (onAST substs param)
            (RetType t_dims (replaceTypeSizes substs t))
            (onExp substs e)
            (onEnv orig_substs closure_env) -- intentional
    Dynamic t ->
      Dynamic $ replaceTypeSizes orig_substs t
    RecordSV fs ->
      RecordSV $ map (fmap (replaceStaticValSizes globals orig_substs)) fs
    SumSV c svs ts ->
      SumSV c (map (replaceStaticValSizes globals orig_substs) svs) $
        map (fmap $ map $ replaceTypeSizes orig_substs) ts
    DynamicFun (e, sv1) sv2 ->
      DynamicFun (onExp orig_substs e, replaceStaticValSizes globals orig_substs sv1) $
        replaceStaticValSizes globals orig_substs sv2
    IntrinsicSV ->
      IntrinsicSV
    HoleSV t loc ->
      HoleSV t loc
  where
    tv substs =
      identityMapper
        { mapOnPatType = pure . replaceTypeSizes substs,
          mapOnStructType = pure . replaceTypeSizes substs,
          mapOnExp = pure . onExp substs,
          mapOnName = pure . onName substs
        }

    onName substs v =
      case M.lookup v substs of
        Just (SubstNamed v') -> qualLeaf v'
        _ -> v

    onExp substs (Var v t loc) =
      case M.lookup (qualLeaf v) substs of
        Just (SubstNamed v') ->
          Var v' t loc
        Just (SubstConst d) ->
          Literal (SignedValue (Int64Value (fromIntegral d))) loc
        Nothing ->
          Var v (replaceTypeSizes substs <$> t) loc
    onExp substs (AppExp (Coerce e te loc) (Info (AppRes t ext))) =
      AppExp (Coerce (onExp substs e) te' loc) (Info (AppRes (replaceTypeSizes substs t) ext))
      where
        te' = onTypeExp substs te
    onExp substs (Lambda params e ret (Info (als, RetType t_dims t)) loc) =
      Lambda
        (map (onAST substs) params)
        (onExp substs e)
        ret
        (Info (als, RetType t_dims (replaceTypeSizes substs t)))
        loc
    onExp substs e = onAST substs e

    onTypeExpDim substs (SizeExp e loc) = SizeExp (onExp substs e) loc
    onTypeExpDim _ (SizeExpAny loc) = SizeExpAny loc

    onTypeArgExp substs (TypeArgExpSize d) =
      TypeArgExpSize (onTypeExpDim substs d)
    onTypeArgExp substs (TypeArgExpType te) =
      TypeArgExpType (onTypeExp substs te)

    onTypeExp substs (TEArray d te loc) =
      TEArray (onTypeExpDim substs d) (onTypeExp substs te) loc
    onTypeExp substs (TEUnique t loc) =
      TEUnique (onTypeExp substs t) loc
    onTypeExp substs (TEApply t1 t2 loc) =
      TEApply (onTypeExp substs t1) (onTypeArgExp substs t2) loc
    onTypeExp substs (TEArrow p t1 t2 loc) =
      TEArrow p (onTypeExp substs t1) (onTypeExp substs t2) loc
    onTypeExp substs (TETuple ts loc) =
      TETuple (map (onTypeExp substs) ts) loc
    onTypeExp substs (TERecord ts loc) =
      TERecord (map (fmap $ onTypeExp substs) ts) loc
    onTypeExp substs (TESum ts loc) =
      TESum (map (fmap $ map $ onTypeExp substs) ts) loc
    onTypeExp substs (TEDim dims t loc) =
      TEDim dims (onTypeExp substs t) loc
    onTypeExp _ (TEVar v loc) =
      TEVar v loc

    onEnv substs =
      M.fromList
        . map (second (onBinding substs))
        . M.toList

    onBinding substs (Binding t bsv) =
      Binding
        (second (replaceTypeSizes substs) <$> t)
        (replaceStaticValSizes globals substs bsv)

    onAST :: ASTMappable x => M.Map VName SizeSubst -> x -> x
    onAST substs = runIdentity . astMap (tv substs)

-- | Returns the defunctionalization environment restricted
-- to the given set of variable names and types.
restrictEnvTo :: FV -> DefM Env
restrictEnvTo (FV m) = asks restrict
  where
    restrict (globals, env) = M.mapMaybeWithKey keep env
      where
        keep k (Binding t sv) = do
          guard $ not $ k `S.member` globals
          u <- uniqueness <$> M.lookup k m
          Just $ Binding t $ restrict' u sv
    restrict' Nonunique (Dynamic t) =
      Dynamic $ t `setUniqueness` Nonunique
    restrict' _ (Dynamic t) =
      Dynamic t
    restrict' u (LambdaSV pat t e env) =
      LambdaSV pat t e $ M.map (restrict'' u) env
    restrict' u (RecordSV fields) =
      RecordSV $ map (fmap $ restrict' u) fields
    restrict' u (SumSV c svs fields) =
      SumSV c (map (restrict' u) svs) fields
    restrict' u (DynamicFun (e, sv1) sv2) =
      DynamicFun (e, restrict' u sv1) $ restrict' u sv2
    restrict' _ IntrinsicSV = IntrinsicSV
    restrict' _ (HoleSV t loc) = HoleSV t loc
    restrict'' u (Binding t sv) = Binding t $ restrict' u sv

-- | Defunctionalization monad.  The Reader environment tracks both
-- the current Env as well as the set of globally defined dynamic
-- functions.  This is used to avoid unnecessarily large closure
-- environments.
newtype DefM a
  = DefM (ReaderT (S.Set VName, Env) (State ([ValBind], VNameSource)) a)
  deriving
    ( Functor,
      Applicative,
      Monad,
      MonadReader (S.Set VName, Env),
      MonadState ([ValBind], VNameSource)
    )

instance MonadFreshNames DefM where
  putNameSource src = modify $ \(x, _) -> (x, src)
  getNameSource = gets snd

-- | Run a computation in the defunctionalization monad. Returns the result of
-- the computation, a new name source, and a list of lifted function declations.
runDefM :: VNameSource -> DefM a -> (a, VNameSource, [ValBind])
runDefM src (DefM m) =
  let (x, (vbs, src')) = runState (runReaderT m mempty) (mempty, src)
   in (x, src', reverse vbs)

addValBind :: ValBind -> DefM ()
addValBind vb = modify $ first (vb :)

-- | Looks up the associated static value for a given name in the environment.
lookupVar :: StructType -> VName -> DefM StaticVal
lookupVar t x = do
  env <- askEnv
  case M.lookup x env of
    Just (Binding (Just (dims, sv_t)) sv) -> do
      globals <- asks fst
      instStaticVal globals dims t sv_t sv
    Just (Binding Nothing sv) ->
      pure sv
    Nothing -- If the variable is unknown, it may refer to the 'intrinsics'
    -- module, which we will have to treat specially.
      | baseTag x <= maxIntrinsicTag -> pure IntrinsicSV
      | otherwise ->
          -- Anything not in scope is going to be an existential size.
          pure $ Dynamic $ Scalar $ Prim $ Signed Int64

-- Like freeInPat, but ignores sizes that are only found in
-- funtion types.
arraySizes :: StructType -> S.Set VName
arraySizes (Scalar Arrow {}) = mempty
arraySizes (Scalar (Record fields)) = foldMap arraySizes fields
arraySizes (Scalar (Sum cs)) = foldMap (foldMap arraySizes) cs
arraySizes (Scalar (TypeVar _ _ _ targs)) =
  mconcat $ map f targs
  where
    f (TypeArgDim (NamedSize d) _) = S.singleton $ qualLeaf d
    f TypeArgDim {} = mempty
    f (TypeArgType t _) = arraySizes t
arraySizes (Scalar Prim {}) = mempty
arraySizes (Array _ _ shape t) =
  arraySizes (Scalar t) <> foldMap dimName (shapeDims shape)
  where
    dimName :: Size -> S.Set VName
    dimName (NamedSize qn) = S.singleton $ qualLeaf qn
    dimName _ = mempty

patternArraySizes :: Pat -> S.Set VName
patternArraySizes = arraySizes . patternStructType

data SizeSubst
  = SubstNamed (QualName VName)
  | SubstConst Int64
  deriving (Eq, Ord, Show)

dimMapping ::
  Monoid a =>
  TypeBase Size a ->
  TypeBase Size a ->
  M.Map VName SizeSubst
dimMapping t1 t2 = execState (matchDims f t1 t2) mempty
  where
    f bound d1 (NamedSize d2)
      | qualLeaf d2 `elem` bound = pure d1
    f _ (NamedSize d1) (NamedSize d2) = do
      modify $ M.insert (qualLeaf d1) $ SubstNamed d2
      pure $ NamedSize d1
    f _ (NamedSize d1) (ConstSize d2) = do
      modify $ M.insert (qualLeaf d1) $ SubstConst d2
      pure $ NamedSize d1
    f _ d _ = pure d

dimMapping' ::
  Monoid a =>
  TypeBase Size a ->
  TypeBase Size a ->
  M.Map VName VName
dimMapping' t1 t2 = M.mapMaybe f $ dimMapping t1 t2
  where
    f (SubstNamed d) = Just $ qualLeaf d
    f _ = Nothing

sizesToRename :: StaticVal -> S.Set VName
sizesToRename (DynamicFun (_, sv1) sv2) =
  sizesToRename sv1 <> sizesToRename sv2
sizesToRename IntrinsicSV =
  mempty
sizesToRename HoleSV {} =
  mempty
sizesToRename Dynamic {} =
  mempty
sizesToRename (RecordSV fs) =
  foldMap (sizesToRename . snd) fs
sizesToRename (SumSV _ svs _) =
  foldMap sizesToRename svs
sizesToRename (LambdaSV param _ _ _) =
  freeInPat param
    <> S.map identName (S.filter couldBeSize $ patIdents param)
  where
    couldBeSize ident =
      unInfo (identType ident) == Scalar (Prim (Signed Int64))

-- When we instantiate a polymorphic StaticVal, we rename all the
-- sizes to avoid name conflicts later on.  This is a bit of a hack...
instStaticVal ::
  MonadFreshNames m =>
  S.Set VName ->
  [VName] ->
  StructType ->
  StructType ->
  StaticVal ->
  m StaticVal
instStaticVal globals dims t sv_t sv = do
  fresh_substs <- mkSubsts $ S.toList $ S.fromList dims <> sizesToRename sv

  let dims' = map (onName fresh_substs) dims
      isDim k _ = k `elem` dims'
      dim_substs =
        M.filterWithKey isDim $ dimMapping (replaceTypeSizes fresh_substs sv_t) t
      replace (SubstNamed k) = fromMaybe (SubstNamed k) $ M.lookup (qualLeaf k) dim_substs
      replace k = k
      substs = M.map replace fresh_substs <> dim_substs

  pure $ replaceStaticValSizes globals substs sv
  where
    mkSubsts names =
      M.fromList . zip names . map (SubstNamed . qualName)
        <$> mapM newName names

    onName substs v =
      case M.lookup v substs of
        Just (SubstNamed v') -> qualLeaf v'
        _ -> v

defuncFun ::
  [VName] ->
  [Pat] ->
  Exp ->
  StructRetType ->
  SrcLoc ->
  DefM (Exp, StaticVal)
defuncFun tparams pats e0 ret loc = do
  -- Extract the first parameter of the lambda and "push" the
  -- remaining ones (if there are any) into the body of the lambda.
  let (pat, ret', e0') = case pats of
        [] -> error "Received a lambda with no parameters."
        [pat'] -> (pat', ret, e0)
        (pat' : pats') ->
          ( pat',
            RetType [] $ funType pats' ret,
            Lambda pats' e0 Nothing (Info (mempty, ret)) loc
          )

  -- Construct a record literal that closes over the environment of
  -- the lambda.  Closed-over 'DynamicFun's are converted to their
  -- closure representation.
  let used =
        freeInExp (Lambda pats e0 Nothing (Info (mempty, ret)) loc)
          `freeWithout` S.fromList tparams
  used_env <- restrictEnvTo used

  -- The closure parts that are sizes are proactively turned into size
  -- parameters.
  let sizes_of_arrays =
        foldMap (arraySizes . toStruct . typeFromSV . bindingSV) used_env
          <> patternArraySizes pat
      notSize = not . (`S.member` sizes_of_arrays)
      (fields, env) =
        second M.fromList
          . unzip
          . map closureFromDynamicFun
          . filter (notSize . fst)
          $ M.toList used_env

  pure
    ( RecordLit fields loc,
      LambdaSV pat ret' e0' env
    )
  where
    closureFromDynamicFun (vn, Binding _ (DynamicFun (clsr_env, sv) _)) =
      let name = nameFromString $ prettyString vn
       in ( RecordFieldExplicit name clsr_env mempty,
            (vn, Binding Nothing sv)
          )
    closureFromDynamicFun (vn, Binding _ sv) =
      let name = nameFromString $ prettyString vn
          tp' = typeFromSV sv
       in ( RecordFieldExplicit
              name
              (Var (qualName vn) (Info tp') mempty)
              mempty,
            (vn, Binding Nothing sv)
          )

-- | Defunctionalization of an expression. Returns the residual expression and
-- the associated static value in the defunctionalization monad.
defuncExp :: Exp -> DefM (Exp, StaticVal)
defuncExp e@Literal {} =
  pure (e, Dynamic $ typeOf e)
defuncExp e@IntLit {} =
  pure (e, Dynamic $ typeOf e)
defuncExp e@FloatLit {} =
  pure (e, Dynamic $ typeOf e)
defuncExp e@StringLit {} =
  pure (e, Dynamic $ typeOf e)
defuncExp (Parens e loc) = do
  (e', sv) <- defuncExp e
  pure (Parens e' loc, sv)
defuncExp (QualParens qn e loc) = do
  (e', sv) <- defuncExp e
  pure (QualParens qn e' loc, sv)
defuncExp (TupLit es loc) = do
  (es', svs) <- mapAndUnzipM defuncExp es
  pure (TupLit es' loc, RecordSV $ zip tupleFieldNames svs)
defuncExp (RecordLit fs loc) = do
  (fs', names_svs) <- mapAndUnzipM defuncField fs
  pure (RecordLit fs' loc, RecordSV names_svs)
  where
    defuncField (RecordFieldExplicit vn e loc') = do
      (e', sv) <- defuncExp e
      pure (RecordFieldExplicit vn e' loc', (vn, sv))
    defuncField (RecordFieldImplicit vn (Info t) loc') = do
      sv <- lookupVar (toStruct t) vn
      case sv of
        -- If the implicit field refers to a dynamic function, we
        -- convert it to an explicit field with a record closing over
        -- the environment and bind the corresponding static value.
        DynamicFun (e, sv') _ ->
          let vn' = baseName vn
           in pure
                ( RecordFieldExplicit vn' e loc',
                  (vn', sv')
                )
        -- The field may refer to a functional expression, so we get the
        -- type from the static value and not the one from the AST.
        _ ->
          let tp = Info $ typeFromSV sv
           in pure (RecordFieldImplicit vn tp loc', (baseName vn, sv))
defuncExp (ArrayLit es t@(Info t') loc) = do
  es' <- mapM defuncExp' es
  pure (ArrayLit es' t loc, Dynamic t')
defuncExp (AppExp (Range e1 me incl loc) res) = do
  e1' <- defuncExp' e1
  me' <- mapM defuncExp' me
  incl' <- mapM defuncExp' incl
  pure
    ( AppExp (Range e1' me' incl' loc) res,
      Dynamic $ appResType $ unInfo res
    )
defuncExp e@(Var qn (Info t) loc) = do
  sv <- lookupVar (toStruct t) (qualLeaf qn)
  case sv of
    -- If the variable refers to a dynamic function, we return its closure
    -- representation (i.e., a record expression capturing the free variables
    -- and a 'LambdaSV' static value) instead of the variable itself.
    DynamicFun closure _ -> pure closure
    -- Intrinsic functions used as variables are eta-expanded, so we
    -- can get rid of them.
    IntrinsicSV -> do
      (pats, body, tp) <- etaExpand (RetType [] (typeOf e)) e
      defuncExp $ Lambda pats body Nothing (Info (mempty, tp)) mempty
    HoleSV _ hole_loc ->
      pure (Hole (Info t) hole_loc, sv)
    _ ->
      let tp = typeFromSV sv
       in pure (Var qn (Info tp) loc, sv)
defuncExp (Hole (Info t) loc) =
  pure (Hole (Info t) loc, HoleSV t loc)
defuncExp (Ascript e0 tydecl loc)
  | orderZero (typeOf e0) = do
      (e0', sv) <- defuncExp e0
      pure (Ascript e0' tydecl loc, sv)
  | otherwise = defuncExp e0
defuncExp (AppExp (Coerce e0 tydecl loc) res)
  | orderZero (typeOf e0) = do
      (e0', sv) <- defuncExp e0
      pure (AppExp (Coerce e0' tydecl loc) res, sv)
  | otherwise = defuncExp e0
defuncExp (AppExp (LetPat sizes pat e1 e2 loc) (Info (AppRes t retext))) = do
  (e1', sv1) <- defuncExp e1
  let env = matchPatSV pat sv1
      pat' = updatePat pat sv1
  (e2', sv2) <- localEnv env $ defuncExp e2
  -- To maintain any sizes going out of scope, we need to compute the
  -- old size substitution induced by retext and also apply it to the
  -- newly computed body type.
  let mapping = dimMapping' (typeOf e2) t
      subst v = fromMaybe v $ M.lookup v mapping
      mapper = identityMapper {mapOnName = pure . subst}
      t' = first (runIdentity . astMap mapper) $ typeOf e2'
  pure (AppExp (LetPat sizes pat' e1' e2' loc) (Info (AppRes t' retext)), sv2)
defuncExp (AppExp (LetFun vn _ _ _) _) =
  error $ "defuncExp: Unexpected LetFun: " ++ show vn
defuncExp (AppExp (If e1 e2 e3 loc) res) = do
  (e1', _) <- defuncExp e1
  (e2', sv) <- defuncExp e2
  (e3', _) <- defuncExp e3
  pure (AppExp (If e1' e2' e3' loc) res, sv)
defuncExp (AppExp (Apply f args loc) (Info appres)) =
  defuncApply f (fmap (first unInfo) args) appres loc
defuncExp (Negate e0 loc) = do
  (e0', sv) <- defuncExp e0
  pure (Negate e0' loc, sv)
defuncExp (Not e0 loc) = do
  (e0', sv) <- defuncExp e0
  pure (Not e0' loc, sv)
defuncExp (Lambda pats e0 _ (Info (_, ret)) loc) =
  defuncFun [] pats e0 ret loc
-- Operator sections are expected to be converted to lambda-expressions
-- by the monomorphizer, so they should no longer occur at this point.
defuncExp OpSection {} = error "defuncExp: unexpected operator section."
defuncExp OpSectionLeft {} = error "defuncExp: unexpected operator section."
defuncExp OpSectionRight {} = error "defuncExp: unexpected operator section."
defuncExp ProjectSection {} = error "defuncExp: unexpected projection section."
defuncExp IndexSection {} = error "defuncExp: unexpected projection section."
defuncExp (AppExp (DoLoop sparams pat e1 form e3 loc) res) = do
  (e1', sv1) <- defuncExp e1
  let env1 = matchPatSV pat sv1
  (form', env2) <- case form of
    For v e2 -> do
      e2' <- defuncExp' e2
      pure (For v e2', envFromIdent v)
    ForIn pat2 e2 -> do
      e2' <- defuncExp' e2
      pure (ForIn pat2 e2', envFromPat pat2)
    While e2 -> do
      e2' <- localEnv env1 $ defuncExp' e2
      pure (While e2', mempty)
  (e3', sv) <- localEnv (env1 <> env2) $ defuncExp e3
  pure (AppExp (DoLoop sparams pat e1' form' e3' loc) res, sv)
  where
    envFromIdent (Ident vn (Info tp) _) =
      M.singleton vn $ Binding Nothing $ Dynamic tp
defuncExp e@(AppExp BinOp {} _) =
  error $ "defuncExp: unexpected binary operator: " ++ prettyString e
defuncExp (Project vn e0 tp@(Info tp') loc) = do
  (e0', sv0) <- defuncExp e0
  case sv0 of
    RecordSV svs -> case lookup vn svs of
      Just sv -> pure (Project vn e0' (Info $ typeFromSV sv) loc, sv)
      Nothing -> error "Invalid record projection."
    Dynamic _ -> pure (Project vn e0' tp loc, Dynamic tp')
    _ -> error $ "Projection of an expression with static value " ++ show sv0
defuncExp (AppExp (LetWith id1 id2 idxs e1 body loc) res) = do
  e1' <- defuncExp' e1
  idxs' <- mapM defuncDimIndex idxs
  let id1_binding = Binding Nothing $ Dynamic $ unInfo $ identType id1
  (body', sv) <-
    localEnv (M.singleton (identName id1) id1_binding) $
      defuncExp body
  pure (AppExp (LetWith id1 id2 idxs' e1' body' loc) res, sv)
defuncExp expr@(AppExp (Index e0 idxs loc) res) = do
  e0' <- defuncExp' e0
  idxs' <- mapM defuncDimIndex idxs
  pure
    ( AppExp (Index e0' idxs' loc) res,
      Dynamic $ typeOf expr
    )
defuncExp (Update e1 idxs e2 loc) = do
  (e1', sv) <- defuncExp e1
  idxs' <- mapM defuncDimIndex idxs
  e2' <- defuncExp' e2
  pure (Update e1' idxs' e2' loc, sv)

-- Note that we might change the type of the record field here.  This
-- is not permitted in the type checker due to problems with type
-- inference, but it actually works fine.
defuncExp (RecordUpdate e1 fs e2 _ loc) = do
  (e1', sv1) <- defuncExp e1
  (e2', sv2) <- defuncExp e2
  let sv = staticField sv1 sv2 fs
  pure
    ( RecordUpdate e1' fs e2' (Info $ typeFromSV sv1) loc,
      sv
    )
  where
    staticField (RecordSV svs) sv2 (f : fs') =
      case lookup f svs of
        Just sv ->
          RecordSV $
            (f, staticField sv sv2 fs') : filter ((/= f) . fst) svs
        Nothing -> error "Invalid record projection."
    staticField (Dynamic t@(Scalar Record {})) sv2 fs'@(_ : _) =
      staticField (svFromType t) sv2 fs'
    staticField _ sv2 _ = sv2
defuncExp (Assert e1 e2 desc loc) = do
  (e1', _) <- defuncExp e1
  (e2', sv) <- defuncExp e2
  pure (Assert e1' e2' desc loc, sv)
defuncExp (Constr name es (Info sum_t@(Scalar (Sum all_fs))) loc) = do
  (es', svs) <- mapAndUnzipM defuncExp es
  let sv =
        SumSV name svs $
          M.toList $
            name `M.delete` M.map (map defuncType) all_fs
      sum_t' = combineTypeShapes sum_t (typeFromSV sv)
  pure (Constr name es' (Info sum_t') loc, sv)
  where
    defuncType ::
      Monoid als =>
      TypeBase Size als ->
      TypeBase Size als
    defuncType (Array as u shape t) = Array as u shape (defuncScalar t)
    defuncType (Scalar t) = Scalar $ defuncScalar t

    defuncScalar ::
      Monoid als =>
      ScalarTypeBase Size als ->
      ScalarTypeBase Size als
    defuncScalar (Record fs) = Record $ M.map defuncType fs
    defuncScalar Arrow {} = Record mempty
    defuncScalar (Sum fs) = Sum $ M.map (map defuncType) fs
    defuncScalar (Prim t) = Prim t
    defuncScalar (TypeVar as u tn targs) = TypeVar as u tn targs
defuncExp (Constr name _ (Info t) loc) =
  error $
    "Constructor "
      ++ prettyString name
      ++ " given type "
      ++ prettyString t
      ++ " at "
      ++ locStr loc
defuncExp (AppExp (Match e cs loc) res) = do
  (e', sv) <- defuncExp e
  csPairs <- mapM (defuncCase sv) cs
  let cs' = fmap fst csPairs
      sv' = snd $ NE.head csPairs
  pure (AppExp (Match e' cs' loc) res, sv')
defuncExp (Attr info e loc) = do
  (e', sv) <- defuncExp e
  pure (Attr info e' loc, sv)

-- | Same as 'defuncExp', except it ignores the static value.
defuncExp' :: Exp -> DefM Exp
defuncExp' = fmap fst . defuncExp

defuncCase :: StaticVal -> Case -> DefM (Case, StaticVal)
defuncCase sv (CasePat p e loc) = do
  let p' = updatePat p sv
      env = matchPatSV p sv
  (e', sv') <- localEnv env $ defuncExp e
  pure (CasePat p' e' loc, sv')

-- | Defunctionalize the function argument to a SOAC by eta-expanding if
-- necessary and then defunctionalizing the body of the introduced lambda.
defuncSoacExp :: Exp -> DefM Exp
defuncSoacExp e@OpSection {} = pure e
defuncSoacExp e@OpSectionLeft {} = pure e
defuncSoacExp e@OpSectionRight {} = pure e
defuncSoacExp e@ProjectSection {} = pure e
defuncSoacExp (Parens e loc) =
  Parens <$> defuncSoacExp e <*> pure loc
defuncSoacExp (Lambda params e0 decl tp loc) = do
  let env = foldMap envFromPat params
  e0' <- localEnv env $ defuncSoacExp e0
  pure $ Lambda params e0' decl tp loc
defuncSoacExp e
  | Scalar Arrow {} <- typeOf e = do
      (pats, body, tp) <- etaExpand (RetType [] (typeOf e)) e
      let env = foldMap envFromPat pats
      body' <- localEnv env $ defuncExp' body
      pure $ Lambda pats body' Nothing (Info (mempty, tp)) mempty
  | otherwise = defuncExp' e

etaExpand :: PatRetType -> Exp -> DefM ([Pat], Exp, StructRetType)
etaExpand e_t e = do
  let (ps, ret) = getType e_t
  -- Some careful hackery to avoid duplicate names.
  (_, (pats, vars)) <- second unzip <$> mapAccumLM f [] ps
  -- Important that we synthesize new existential names and substitute
  -- them into the (body) return type.
  ext' <- mapM newName $ retDims ret
  let extsubst =
        M.fromList . zip (retDims ret) $
          map (SizeSubst . NamedSize . qualName) ext'
      ret' = applySubst (`M.lookup` extsubst) ret
      e' =
        mkApply
          e
          (zip3 (map (diet . snd . snd) ps) (repeat Nothing) vars)
          (AppRes (retType ret') ext')
  pure (pats, e', second (const ()) ret)
  where
    getType (RetType _ (Scalar (Arrow _ p d t1 t2))) =
      let (ps, r) = getType t2
       in ((p, (d, t1)) : ps, r)
    getType t = ([], t)

    f prev (p, (d, t)) = do
      let t' =
            fromStruct t
              `setUniqueness` case d of
                Consume -> Unique
                Observe -> Nonunique
      x <- case p of
        Named x | x `notElem` prev -> pure x
        _ -> newNameFromString "x"
      pure
        ( x : prev,
          ( Id x (Info t') mempty,
            Var (qualName x) (Info t') mempty
          )
        )

-- | Defunctionalize an indexing of a single array dimension.
defuncDimIndex :: DimIndexBase Info VName -> DefM (DimIndexBase Info VName)
defuncDimIndex (DimFix e1) = DimFix . fst <$> defuncExp e1
defuncDimIndex (DimSlice me1 me2 me3) =
  DimSlice <$> defunc' me1 <*> defunc' me2 <*> defunc' me3
  where
    defunc' = mapM defuncExp'

-- | Defunctionalize a let-bound function, while preserving parameters
-- that have order 0 types (i.e., non-functional).
defuncLet ::
  [VName] ->
  [Pat] ->
  Exp ->
  StructRetType ->
  DefM ([VName], [Pat], Exp, StaticVal)
defuncLet dims ps@(pat : pats) body (RetType ret_dims rettype)
  | patternOrderZero pat = do
      let bound_by_pat = (`S.member` freeInPat pat)
          -- Take care to not include more size parameters than necessary.
          (pat_dims, rest_dims) = partition bound_by_pat dims
          env = envFromPat pat <> envFromDimNames pat_dims
      (rest_dims', pats', body', sv) <-
        localEnv env $ defuncLet rest_dims pats body $ RetType ret_dims rettype
      closure <- defuncFun dims ps body (RetType ret_dims rettype) mempty
      pure
        ( pat_dims ++ rest_dims',
          pat : pats',
          body',
          DynamicFun closure sv
        )
  | otherwise = do
      (e, sv) <- defuncFun dims ps body (RetType ret_dims rettype) mempty
      pure ([], [], e, sv)
defuncLet _ [] body (RetType _ rettype) = do
  (body', sv) <- defuncExp body
  pure ([], [], body', imposeType sv rettype)
  where
    imposeType Dynamic {} t =
      Dynamic $ fromStruct t
    imposeType (RecordSV fs1) (Scalar (Record fs2)) =
      RecordSV $ M.toList $ M.intersectionWith imposeType (M.fromList fs1) fs2
    imposeType sv _ = sv

sizesForAll :: MonadFreshNames m => S.Set VName -> [Pat] -> m ([VName], [Pat])
sizesForAll bound_sizes params = do
  (params', sizes) <- runStateT (mapM (astMap tv) params) mempty
  pure (S.toList sizes, params')
  where
    bound = bound_sizes <> foldMap patNames params
    tv = identityMapper {mapOnPatType = bitraverse onDim pure}
    onDim (AnySize (Just v)) = do
      modify $ S.insert v
      pure $ NamedSize $ qualName v
    onDim (AnySize Nothing) = do
      v <- lift $ newVName "size"
      modify $ S.insert v
      pure $ NamedSize $ qualName v
    onDim (NamedSize d) = do
      unless (qualLeaf d `S.member` bound) $
        modify $
          S.insert $
            qualLeaf d
      pure $ NamedSize d
    onDim d = pure d

unRetType :: StructRetType -> StructType
unRetType (RetType [] t) = t
unRetType (RetType ext t) = first onDim t
  where
    onDim (NamedSize d) | qualLeaf d `elem` ext = AnySize Nothing
    onDim d = d

defuncApplyFunction :: Exp -> Int -> DefM (Exp, StaticVal)
defuncApplyFunction e@(Var qn (Info t) loc) num_args = do
  let (argtypes, _) = unfoldFunType t
  sv <- lookupVar (toStruct t) (qualLeaf qn)

  case sv of
    DynamicFun _ _
      | fullyApplied sv num_args -> do
          -- We still need to update the types in case the dynamic
          -- function returns a higher-order term.
          let (argtypes', rettype) = dynamicFunType sv argtypes
          pure (Var qn (Info (foldFunType argtypes' $ RetType [] rettype)) loc, sv)
      | otherwise -> do
          fname <- newVName $ "dyn_" <> baseString (qualLeaf qn)
          let (pats, e0, sv') = liftDynFun (prettyString qn) sv num_args
              (argtypes', rettype) = dynamicFunType sv' argtypes
              dims' = mempty

          -- Ensure that no parameter sizes are AnySize.  The internaliser
          -- expects this.  This is easy, because they are all
          -- first-order.
          globals <- asks fst
          let bound_sizes = S.fromList dims' <> globals
          (missing_dims, pats') <- sizesForAll bound_sizes pats

          liftValDec fname (RetType [] $ toStruct rettype) (dims' ++ missing_dims) pats' e0
          pure
            ( Var
                (qualName fname)
                (Info (foldFunType argtypes' $ RetType [] $ fromStruct rettype))
                loc,
              sv'
            )
    IntrinsicSV -> pure (e, IntrinsicSV)
    _ -> pure (Var qn (Info (typeFromSV sv)) loc, sv)
defuncApplyFunction e _ = defuncExp e

-- Embed some information about the original function
-- into the name of the lifted function, to make the
-- result slightly more human-readable.
liftedName :: Int -> Exp -> String
liftedName i (Var f _ _) =
  "defunc_" ++ show i ++ "_" ++ baseString (qualLeaf f)
liftedName i (AppExp (Apply f _ _) _) =
  liftedName (i + 1) f
liftedName _ _ = "defunc"

defuncApplyArg ::
  String ->
  (Exp, StaticVal) ->
  (((Diet, Maybe VName), Exp), [(Diet, StructType)]) ->
  DefM (Exp, StaticVal)
defuncApplyArg fname_s (f', f_sv@(LambdaSV pat lam_e_t lam_e closure_env)) (((d, argext), arg), _) = do
  (arg', arg_sv) <- defuncExp arg
  let env' = matchPatSV pat arg_sv
      dims = mempty
  (lam_e', sv) <-
    localNewEnv (env' <> closure_env) $
      defuncExp lam_e

  let closure_pat = buildEnvPat dims closure_env
      pat' = updatePat pat arg_sv

  globals <- asks fst

  -- Lift lambda to top-level function definition.  We put in
  -- a lot of effort to try to infer the uniqueness attributes
  -- of the lifted function, but this is ultimately all a sham
  -- and a hack.  There is some piece we're missing.
  let params = [closure_pat, pat']
      params_for_rettype = params ++ svParams f_sv ++ svParams arg_sv
      svParams (LambdaSV sv_pat _ _ _) = [sv_pat]
      svParams _ = []
      lifted_rettype = buildRetType closure_env params_for_rettype (unRetType lam_e_t) $ typeOf lam_e'

      already_bound =
        globals
          <> S.fromList dims
          <> S.map identName (foldMap patIdents params)

      more_dims =
        S.toList $
          S.filter (`S.notMember` already_bound) $
            foldMap patternArraySizes params

  -- Ensure that no parameter sizes are AnySize.  The internaliser
  -- expects this.  This is easy, because they are all
  -- first-order.
  let bound_sizes = S.fromList (dims <> more_dims) <> globals
  (missing_dims, params') <- sizesForAll bound_sizes params

  fname <- newNameFromString fname_s
  liftValDec
    fname
    (RetType [] $ toStruct lifted_rettype)
    (dims ++ more_dims ++ missing_dims)
    params'
    lam_e'

  let f_t = toStruct $ typeOf f'
      arg_t = toStruct $ typeOf arg'
      d1 = Observe
      fname_t = foldFunType [(d1, f_t), (d, arg_t)] $ RetType [] lifted_rettype
      fname' = Var (qualName fname) (Info fname_t) (srclocOf arg)
      callret = AppRes lifted_rettype []

  pure
    ( mkApply fname' [(Observe, Nothing, f'), (Observe, argext, arg')] callret,
      sv
    )
-- If 'f' is a dynamic function, we just leave the application in
-- place, but we update the types since it may be partially
-- applied or return a higher-order value.
defuncApplyArg _ (f', DynamicFun _ sv) (((d, argext), arg), argtypes) = do
  (arg', _) <- defuncExp arg
  let (argtypes', rettype) = dynamicFunType sv argtypes
      restype = foldFunType argtypes' (RetType [] rettype)
      callret = AppRes restype []
      apply_e = mkApply f' [(d, argext, arg')] callret
  pure (apply_e, sv)
--
defuncApplyArg _ (_, sv) _ =
  error $ "defuncApplyArg: cannot apply StaticVal\n" <> show sv

updateReturn :: AppRes -> Exp -> Exp
updateReturn (AppRes ret1 ext1) (AppExp apply (Info (AppRes ret2 ext2))) =
  AppExp apply $ Info $ AppRes (combineTypeShapes ret1 ret2) (ext1 <> ext2)
updateReturn _ e = e

defuncApply :: Exp -> NE.NonEmpty ((Diet, Maybe VName), Exp) -> AppRes -> SrcLoc -> DefM (Exp, StaticVal)
defuncApply f args appres loc = do
  (f', f_sv) <- defuncApplyFunction f (length args)
  case f_sv of
    IntrinsicSV -> do
      args' <- fmap (first Info) <$> traverse (traverse defuncSoacExp) args
      let e' = AppExp (Apply f' args' loc) (Info appres)
      intrinsicOrHole e'
    HoleSV {} -> do
      args' <- fmap (first Info) <$> traverse (traverse $ fmap fst . defuncExp) args
      let e' = AppExp (Apply f' args' loc) (Info appres)
      intrinsicOrHole e'
    _ -> do
      let fname = liftedName 0 f
          (argtypes, _) = unfoldFunType $ typeOf f
      fmap (first $ updateReturn appres) $
        foldM (defuncApplyArg fname) (f', f_sv) $
          NE.zip args $
            NE.tails argtypes
  where
    intrinsicOrHole e' = do
      -- If the intrinsic is fully applied, then we are done.
      -- Otherwise we need to eta-expand it and recursively
      -- defunctionalise. XXX: might it be better to simply eta-expand
      -- immediately any time we encounter a non-fully-applied
      -- intrinsic?
      if null $ fst $ unfoldFunType $ appResType appres
        then pure (e', Dynamic $ appResType appres)
        else do
          (pats, body, tp) <- etaExpand (RetType [] (typeOf e')) e'
          defuncExp $ Lambda pats body Nothing (Info (mempty, tp)) mempty

-- | Check if a 'StaticVal' and a given application depth corresponds
-- to a fully applied dynamic function.
fullyApplied :: StaticVal -> Int -> Bool
fullyApplied (DynamicFun _ sv) depth
  | depth == 0 = False
  | depth > 0 = fullyApplied sv (depth - 1)
fullyApplied _ _ = True

-- | Converts a dynamic function 'StaticVal' into a list of
-- dimensions, a list of parameters, a function body, and the
-- appropriate static value for applying the function at the given
-- depth of partial application.
liftDynFun :: String -> StaticVal -> Int -> ([Pat], Exp, StaticVal)
liftDynFun _ (DynamicFun (e, sv) _) 0 = ([], e, sv)
liftDynFun s (DynamicFun clsr@(_, LambdaSV pat _ _ _) sv) d
  | d > 0 =
      let (pats, e', sv') = liftDynFun s sv (d - 1)
       in (pat : pats, e', DynamicFun clsr sv')
liftDynFun s sv d =
  error $
    s
      ++ " Tried to lift a StaticVal "
      ++ take 100 (show sv)
      ++ ", but expected a dynamic function.\n"
      ++ prettyString d

-- | Converts a pattern to an environment that binds the individual names of the
-- pattern to their corresponding types wrapped in a 'Dynamic' static value.
envFromPat :: Pat -> Env
envFromPat pat = case pat of
  TuplePat ps _ -> foldMap envFromPat ps
  RecordPat fs _ -> foldMap (envFromPat . snd) fs
  PatParens p _ -> envFromPat p
  PatAttr _ p _ -> envFromPat p
  Id vn (Info t) _ -> M.singleton vn $ Binding Nothing $ Dynamic t
  Wildcard _ _ -> mempty
  PatAscription p _ _ -> envFromPat p
  PatLit {} -> mempty
  PatConstr _ _ ps _ -> foldMap envFromPat ps

envFromDimNames :: [VName] -> Env
envFromDimNames = M.fromList . flip zip (repeat d)
  where
    d = Binding Nothing $ Dynamic $ Scalar $ Prim $ Signed Int64

-- | Create a new top-level value declaration with the given function name,
-- return type, list of parameters, and body expression.
liftValDec :: VName -> StructRetType -> [VName] -> [Pat] -> Exp -> DefM ()
liftValDec fname (RetType ret_dims ret) dims pats body = addValBind dec
  where
    dims' = map (`TypeParamDim` mempty) dims
    -- FIXME: this pass is still not correctly size-preserving, so
    -- forget those return sizes that we forgot to propagate along
    -- the way.  Hopefully the internaliser is conservative and
    -- will insert reshapes...
    bound_here = S.fromList dims <> S.map identName (foldMap patIdents pats)
    mkExt v
      | not $ v `S.member` bound_here = Just v
    mkExt _ = Nothing
    rettype_st = RetType (mapMaybe mkExt (S.toList (freeInType ret)) ++ ret_dims) ret

    dec =
      ValBind
        { valBindEntryPoint = Nothing,
          valBindName = fname,
          valBindRetDecl = Nothing,
          valBindRetType = Info rettype_st,
          valBindTypeParams = dims',
          valBindParams = pats,
          valBindBody = body,
          valBindDoc = Nothing,
          valBindAttrs = mempty,
          valBindLocation = mempty
        }

-- | Given a closure environment, construct a record pattern that
-- binds the closed over variables.  Insert wildcard for any patterns
-- that would otherwise clash with size parameters.
buildEnvPat :: [VName] -> Env -> Pat
buildEnvPat sizes env = RecordPat (map buildField $ M.toList env) mempty
  where
    buildField (vn, Binding _ sv) =
      ( nameFromString (prettyString vn),
        if vn `elem` sizes
          then Wildcard (Info $ typeFromSV sv) mempty
          else Id vn (Info $ typeFromSV sv) mempty
      )

-- | Given a closure environment pattern and the type of a term,
-- construct the type of that term, where uniqueness is set to
-- `Nonunique` for those arrays that are bound in the environment or
-- pattern (except if they are unique there).  This ensures that a
-- lifted function can create unique arrays as long as they do not
-- alias any of its parameters.  XXX: it is not clear that this is a
-- sufficient property, unfortunately.
buildRetType :: Env -> [Pat] -> StructType -> PatType -> PatType
buildRetType env pats = comb
  where
    bound =
      S.fromList (M.keys env) <> S.map identName (foldMap patIdents pats)
    boundAsUnique v =
      maybe False (unique . unInfo . identType) $
        find ((== v) . identName) $
          S.toList $
            foldMap patIdents pats
    problematic v = (v `S.member` bound) && not (boundAsUnique v)
    comb (Scalar (Record fs_annot)) (Scalar (Record fs_got)) =
      Scalar $ Record $ M.intersectionWith comb fs_annot fs_got
    comb (Scalar (Sum cs_annot)) (Scalar (Sum cs_got)) =
      Scalar $ Sum $ M.intersectionWith (zipWith comb) cs_annot cs_got
    comb (Scalar Arrow {}) t =
      descend t
    comb got et =
      descend $ fromStruct got `setAliases` aliases et

    descend t@Array {}
      | any (problematic . aliasVar) (aliases t) = t `setUniqueness` Nonunique
    descend (Scalar (Record t)) = Scalar $ Record $ fmap descend t
    descend t = t

-- | Compute the corresponding type for the *representation* of a
-- given static value (not the original possibly higher-order value).
typeFromSV :: StaticVal -> PatType
typeFromSV (Dynamic tp) =
  tp
typeFromSV (LambdaSV _ _ _ env) =
  Scalar . Record . M.fromList $
    map (bimap (nameFromString . prettyString) (typeFromSV . bindingSV)) $
      M.toList env
typeFromSV (RecordSV ls) =
  let ts = map (fmap typeFromSV) ls
   in Scalar $ Record $ M.fromList ts
typeFromSV (DynamicFun (_, sv) _) =
  typeFromSV sv
typeFromSV (SumSV name svs fields) =
  let svs' = map typeFromSV svs
   in Scalar $ Sum $ M.insert name svs' $ M.fromList fields
typeFromSV (HoleSV t _) =
  t
typeFromSV IntrinsicSV =
  error "Tried to get the type from the static value of an intrinsic."

-- | Construct the type for a fully-applied dynamic function from its
-- static value and the original types of its arguments.
dynamicFunType :: StaticVal -> [(Diet, StructType)] -> ([(Diet, PatType)], PatType)
dynamicFunType (DynamicFun _ sv) (p : ps) =
  let (ps', ret) = dynamicFunType sv ps
   in (second fromStruct p : ps', ret)
dynamicFunType sv _ = ([], typeFromSV sv)

-- | Match a pattern with its static value. Returns an environment with
-- the identifier components of the pattern mapped to the corresponding
-- subcomponents of the static value.
matchPatSV :: PatBase Info VName -> StaticVal -> Env
matchPatSV (TuplePat ps _) (RecordSV ls) =
  mconcat $ zipWith (\p (_, sv) -> matchPatSV p sv) ps ls
matchPatSV (RecordPat ps _) (RecordSV ls)
  | ps' <- sortOn fst ps,
    ls' <- sortOn fst ls,
    map fst ps' == map fst ls' =
      mconcat $ zipWith (\(_, p) (_, sv) -> matchPatSV p sv) ps' ls'
matchPatSV (PatParens pat _) sv = matchPatSV pat sv
matchPatSV (PatAttr _ pat _) sv = matchPatSV pat sv
matchPatSV (Id vn (Info t) _) sv =
  -- When matching a pattern with a zero-order STaticVal, the type of
  -- the pattern wins out.  This is important when matching a
  -- nonunique pattern with a unique value.
  if orderZeroSV sv
    then dim_env <> M.singleton vn (Binding Nothing $ Dynamic t)
    else dim_env <> M.singleton vn (Binding Nothing sv)
  where
    dim_env =
      M.fromList $ map (,i64) $ S.toList $ freeInType t
    i64 = Binding Nothing $ Dynamic $ Scalar $ Prim $ Signed Int64
matchPatSV (Wildcard _ _) _ = mempty
matchPatSV (PatAscription pat _ _) sv = matchPatSV pat sv
matchPatSV PatLit {} _ = mempty
matchPatSV (PatConstr c1 _ ps _) (SumSV c2 ls fs)
  | c1 == c2 =
      mconcat $ zipWith matchPatSV ps ls
  | Just ts <- lookup c1 fs =
      mconcat $ zipWith matchPatSV ps $ map svFromType ts
  | otherwise =
      error $ "matchPatSV: missing constructor in type: " ++ prettyString c1
matchPatSV (PatConstr c1 _ ps _) (Dynamic (Scalar (Sum fs)))
  | Just ts <- M.lookup c1 fs =
      mconcat $ zipWith matchPatSV ps $ map svFromType ts
  | otherwise =
      error $ "matchPatSV: missing constructor in type: " ++ prettyString c1
matchPatSV pat (Dynamic t) = matchPatSV pat $ svFromType t
matchPatSV pat (HoleSV t _) = matchPatSV pat $ svFromType t
matchPatSV pat sv =
  error $
    "Tried to match pattern\n"
      ++ prettyString pat
      ++ "\n with static value\n"
      ++ show sv

orderZeroSV :: StaticVal -> Bool
orderZeroSV Dynamic {} = True
orderZeroSV (RecordSV fields) = all (orderZeroSV . snd) fields
orderZeroSV _ = False

-- | Given a pattern and the static value for the defunctionalized argument,
-- update the pattern to reflect the changes in the types.
updatePat :: Pat -> StaticVal -> Pat
updatePat (TuplePat ps loc) (RecordSV svs) =
  TuplePat (zipWith updatePat ps $ map snd svs) loc
updatePat (RecordPat ps loc) (RecordSV svs)
  | ps' <- sortOn fst ps,
    svs' <- sortOn fst svs =
      RecordPat
        (zipWith (\(n, p) (_, sv) -> (n, updatePat p sv)) ps' svs')
        loc
updatePat (PatParens pat loc) sv =
  PatParens (updatePat pat sv) loc
updatePat (PatAttr attr pat loc) sv =
  PatAttr attr (updatePat pat sv) loc
updatePat (Id vn (Info tp) loc) sv =
  Id vn (Info $ comb tp (typeFromSV sv `setUniqueness` Nonunique)) loc
  where
    -- Preserve any original zeroth-order types.
    comb (Scalar Arrow {}) t2 = t2
    comb (Scalar (Record m1)) (Scalar (Record m2)) =
      Scalar $ Record $ M.intersectionWith comb m1 m2
    comb (Scalar (Sum m1)) (Scalar (Sum m2)) =
      Scalar $ Sum $ M.intersectionWith (zipWith comb) m1 m2
    comb t1 _ = t1 -- t1 must be array or prim.
updatePat pat@(Wildcard (Info tp) loc) sv
  | orderZero tp = pat
  | otherwise = Wildcard (Info $ typeFromSV sv) loc
updatePat (PatAscription pat _ _) sv =
  updatePat pat sv
updatePat p@PatLit {} _ = p
updatePat pat@(PatConstr c1 (Info t) ps loc) sv@(SumSV _ svs _)
  | orderZero t = pat
  | otherwise = PatConstr c1 (Info t') ps' loc
  where
    t' = typeFromSV sv `setUniqueness` Nonunique
    ps' = zipWith updatePat ps svs
updatePat (PatConstr c1 _ ps loc) (Dynamic t) =
  PatConstr c1 (Info t) ps loc
updatePat pat (Dynamic t) = updatePat pat (svFromType t)
updatePat pat (HoleSV t _) = updatePat pat (svFromType t)
updatePat pat sv =
  error $
    "Tried to update pattern\n"
      ++ prettyString pat
      ++ "\nto reflect the static value\n"
      ++ show sv

-- | Convert a record (or tuple) type to a record static value. This is used for
-- "unwrapping" tuples and records that are nested in 'Dynamic' static values.
svFromType :: PatType -> StaticVal
svFromType (Scalar (Record fs)) = RecordSV . M.toList $ M.map svFromType fs
svFromType t = Dynamic t

-- | Defunctionalize a top-level value binding. Returns the
-- transformed result as well as an environment that binds the name of
-- the value binding to the static value of the transformed body.  The
-- boolean is true if the function is a 'DynamicFun'.
defuncValBind :: ValBind -> DefM (ValBind, Env)
-- Eta-expand entry points with a functional return type.
defuncValBind (ValBind entry name _ (Info rettype) tparams params body _ attrs loc)
  | Scalar Arrow {} <- retType rettype = do
      (body_pats, body', rettype') <- etaExpand (second (const mempty) rettype) body
      defuncValBind $
        ValBind
          entry
          name
          Nothing
          (Info rettype')
          tparams
          (params <> body_pats)
          body'
          Nothing
          attrs
          loc
defuncValBind valbind@(ValBind _ name retdecl (Info (RetType ret_dims rettype)) tparams params body _ _ _) = do
  when (any isTypeParam tparams) $
    error $
      show name
        ++ " has type parameters, "
        ++ "but the defunctionaliser expects a monomorphic input program."
  (tparams', params', body', sv) <-
    defuncLet (map typeParamName tparams) params body $ RetType ret_dims rettype
  globals <- asks fst
  let bound_sizes = foldMap patNames params' <> S.fromList tparams' <> globals
      rettype' =
        -- FIXME: dubious that we cannot assume that all sizes in the
        -- body are in scope.  This is because when we insert
        -- applications of lifted functions, we don't properly update
        -- the types in the return type annotation.
        combineTypeShapes rettype $ first (anyDimIfNotBound bound_sizes) $ toStruct $ typeOf body'
      ret_dims' = filter (`S.member` freeInType rettype') ret_dims
  (missing_dims, params'') <- sizesForAll bound_sizes params'

  pure
    ( valbind
        { valBindRetDecl = retdecl,
          valBindRetType =
            Info $
              if null params'
                then RetType ret_dims' $ rettype' `setUniqueness` Nonunique
                else RetType ret_dims' rettype',
          valBindTypeParams =
            map (`TypeParamDim` mempty) $ tparams' ++ missing_dims,
          valBindParams = params'',
          valBindBody = body'
        },
      M.singleton name $
        Binding
          (Just (first (map typeParamName) (valBindTypeScheme valbind)))
          sv
    )
  where
    anyDimIfNotBound bound_sizes (NamedSize v)
      | qualLeaf v `S.notMember` bound_sizes = AnySize $ Just $ qualLeaf v
    anyDimIfNotBound _ d = d

-- | Defunctionalize a list of top-level declarations.
defuncVals :: [ValBind] -> DefM ()
defuncVals [] = pure ()
defuncVals (valbind : ds) = do
  (valbind', env) <- defuncValBind valbind
  addValBind valbind'
  let globals = valBindBound valbind'
  localEnv env $ areGlobal globals $ defuncVals ds

{-# NOINLINE transformProg #-}

-- | Transform a list of top-level value bindings. May produce new
-- lifted function definitions, which are placed in front of the
-- resulting list of declarations.
transformProg :: MonadFreshNames m => [ValBind] -> m [ValBind]
transformProg decs = modifyNameSource $ \namesrc ->
  let ((), namesrc', decs') = runDefM namesrc $ defuncVals decs
   in (decs', namesrc')
