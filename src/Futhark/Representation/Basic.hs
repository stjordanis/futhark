{-# LANGUAGE TypeFamilies #-}
-- | A simple representation with known shapes, but no other
-- particular information.
module Futhark.Representation.Basic
       ( -- * The Lore definition
         Basic
         -- * Syntax types
       , Prog
       , Body
       , Binding
       , Pattern
       , PrimOp
       , LoopOp
       , Exp
       , Lambda
       , ExtLambda
       , FunDec
       , FParam
       , LParam
       , RetType
       , PatElem
         -- * Module re-exports
       , module Futhark.Representation.AST.Attributes
       , module Futhark.Representation.AST.Traversals
       , module Futhark.Representation.AST.Pretty
       , module Futhark.Representation.AST.Syntax
       , AST.LambdaT(Lambda)
       , AST.ExtLambdaT(ExtLambda)
       , AST.BodyT(Body)
       , AST.PatternT(Pattern)
       , AST.PatElemT(PatElem)
       , AST.ProgT(Prog)
       , AST.ExpT(PrimOp)
       , AST.ExpT(LoopOp)
       , AST.FunDecT(FunDec)
       , AST.ParamT(Param)
         -- Utility
       , basicPattern
       , basicPattern'
         -- Removing lore
       , removeProgLore
       , removeFunDecLore
       , removeBodyLore
       )
where

import Control.Monad

import qualified Futhark.Representation.AST.Annotations as Annotations
import qualified Futhark.Representation.AST.Lore as Lore
import qualified Futhark.Representation.AST.Syntax as AST
import Futhark.Representation.AST.Syntax
  hiding (Prog, PrimOp, LoopOp, Exp, Body, Binding,
          Pattern, Lambda, ExtLambda, FunDec, FParam, LParam,
          RetType, PatElem)
import Futhark.Representation.AST.Attributes
import Futhark.Representation.AST.Traversals
import Futhark.Representation.AST.Pretty
import Futhark.Transform.Rename
import Futhark.Binder
import Futhark.Construct
import Futhark.Transform.Substitute
import qualified Futhark.TypeCheck as TypeCheck
import Futhark.Analysis.Rephrase

-- This module could be written much nicer if Haskell had functors
-- like Standard ML.  Instead, we have to abuse the namespace/module
-- system.

-- | The lore for the basic representation.
data Basic = Basic

instance Annotations.Annotations Basic where

instance Lore.Lore Basic where
  representative = Futhark.Representation.Basic.Basic

  loopResultContext _ res merge =
    loopShapeContext res $ map paramIdent merge

type Prog = AST.Prog Basic
type PrimOp = AST.PrimOp Basic
type LoopOp = AST.LoopOp Basic
type Exp = AST.Exp Basic
type Body = AST.Body Basic
type Binding = AST.Binding Basic
type Pattern = AST.Pattern Basic
type Lambda = AST.Lambda Basic
type ExtLambda = AST.ExtLambda Basic
type FunDec = AST.FunDecT Basic
type FParam = AST.FParam Basic
type LParam = AST.LParam Basic
type RetType = AST.RetType Basic
type PatElem = AST.PatElem Basic

instance TypeCheck.Checkable Basic where
  checkExpLore = return
  checkBodyLore = return
  checkFParamLore _ = TypeCheck.checkType
  checkLParamLore _ = TypeCheck.checkType
  checkLetBoundLore _ = TypeCheck.checkType
  checkRetType = mapM_ TypeCheck.checkExtType . retTypeValues
  matchPattern pat e = do
    et <- expExtType e
    TypeCheck.matchExtPattern (patternElements pat) et
  basicFParam _ name t =
    AST.Param name (AST.Basic t)
  basicLParam _ name t =
    AST.Param name (AST.Basic t)
  matchReturnType name (ExtRetType ts) =
    TypeCheck.matchExtReturnType name $ map fromDecl ts

instance Renameable Basic where
instance Substitutable Basic where
instance Proper Basic where

instance Bindable Basic where
  mkBody = AST.Body ()
  mkLet context values =
    AST.Let (basicPattern context values) ()
  mkLetNames names e = do
    et <- expExtType e
    (ts, shapes) <- instantiateShapes' et
    let shapeElems = [ AST.PatElem shape BindVar shapet
                     | Ident shape shapet <- shapes
                     ]
        mkValElem (name, BindVar) t =
          return $ AST.PatElem name BindVar t
        mkValElem (name, bindage@(BindInPlace _ src _)) _ = do
          srct <- lookupType src
          return $ AST.PatElem name bindage srct
    valElems <- zipWithM mkValElem names ts
    return $ AST.Let (AST.Pattern shapeElems valElems) () e

instance PrettyLore Basic where

basicPattern :: [(Ident,Bindage)] -> [(Ident,Bindage)] -> Pattern
basicPattern context values =
  AST.Pattern (map patElem context) (map patElem values)
  where patElem (Ident name t,bindage) = AST.PatElem name bindage t

basicPattern' :: [Ident] -> [Ident] -> Pattern
basicPattern' context values =
  basicPattern (map addBindVar context) (map addBindVar values)
    where addBindVar name = (name, BindVar)

removeLore :: Lore.Lore lore => Rephraser lore Basic
removeLore =
  Rephraser { rephraseExpLore = const ()
            , rephraseLetBoundLore = typeOf
            , rephraseBodyLore = const ()
            , rephraseFParamLore = declTypeOf
            , rephraseLParamLore = typeOf
            , rephraseRetType = removeRetTypeLore
            }

removeProgLore :: Lore.Lore lore => AST.Prog lore -> Prog
removeProgLore = rephraseProg removeLore

removeFunDecLore :: Lore.Lore lore => AST.FunDec lore -> FunDec
removeFunDecLore = rephraseFunDec removeLore

removeBodyLore :: Lore.Lore lore => AST.Body lore -> Body
removeBodyLore = rephraseBody removeLore

removeRetTypeLore :: IsRetType rt => rt -> RetType
removeRetTypeLore = ExtRetType . retTypeValues
