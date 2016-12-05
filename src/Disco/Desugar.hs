{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE GADTs                    #-}
{-# LANGUAGE MultiParamTypeClasses    #-}
{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE TemplateHaskell          #-}
{-# LANGUAGE UndecidableInstances     #-}
{-# LANGUAGE ViewPatterns             #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Disco.Desugar
-- Copyright   :  (c) 2016 disco team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  byorgey@gmail.com
--
-- Desugaring the typechecked surface language to the untyped core
-- language.
--
-----------------------------------------------------------------------------

module Disco.Desugar
       ( -- * Desugaring monad
         DSM, runDSM

         -- * Programs and terms
       , desugarDefn, desugarTerm, desugarUOp, desugarBOp

         -- * Case expressions and patterns
       , desugarBranch, desugarGuards, desugarPattern
       )
       where

import           Control.Arrow           ((+++))
import           Data.Ratio

import           Unbound.LocallyNameless

import           Disco.AST.Core
import           Disco.AST.Surface
import           Disco.AST.Typed
import           Disco.Typecheck
import           Disco.Types

-- | The desugaring monad.  Currently, needs only the ability to
--   generate fresh names (to deal with binders).
type DSM = LFreshM

-- | Run a computation in the desugaring monad.
runDSM :: DSM a -> a
runDSM = runLFreshM

-- | Desugar a definition (of the form @f pat1 .. patn = term@, but
--   without the name @f@ of the thing being defined) into a core
--   language term.  Each pattern desugars to an anonymous function,
--   appropriately combined with a case expression for non-variable
--   patterns.
--
--   For example, @f n (x,y) = n*x + y@ desugars to something like
--
--   @
--     n -> p -> { n*x + y  when p = (x,y)
--   @
desugarDefn :: Defn -> DSM Core
desugarDefn def =
  lunbind def $ \(pats, body) -> go pats body
  where

    -- No patterns left, just desugar the body.
    go []     body = desugarTerm body

    -- Desugar the first pattern into a lambda.
    go (p:ps) body = do

      -- Desugar the pattern itself, and the rest of the definition.
      let cp = desugarPattern p
      rest <- go ps body

      case cp of
        -- If the pattern is a variable, desugar to a simple lambda, @x -> rest@.
        CPVar x -> return $ CAbs (bind x rest)

        -- Otherwise, desugar to a lambda containing a case, @arg -> { rest when arg = p@.
        _       -> do
          arg  <- lfresh (string2Name "arg")
          avoid [AnyName arg] $ do
          return $
            CAbs (bind arg (CCase [bind (CGCons (rebind (embed $ CVar arg, cp) CGEmpty)) rest]))

-- | Desugar a typechecked term.
desugarTerm :: ATerm -> DSM Core
desugarTerm (ATVar _ x)   = return $ CVar (translate x)
desugarTerm ATUnit        = return $ CCons 0 []
desugarTerm (ATBool b)    = return $ CCons (fromEnum b) []
desugarTerm (ATAbs _ lam) =
  lunbind lam $ \(x,t) -> do
  dt <- desugarTerm t
  return $ CAbs (bind (translate x) dt)
desugarTerm (ATApp ty t1 t2) =
  CApp (strictness ty) <$> desugarTerm t1 <*> desugarTerm t2
desugarTerm (ATPair _ t1 t2) =
  CCons 0 <$> mapM desugarTerm [t1,t2]
desugarTerm (ATInj _ s t) =
  CCons (fromEnum s) <$> mapM desugarTerm [t]
desugarTerm (ATNat n) = return $ CNat n
desugarTerm (ATUn _ op t) =
  desugarUOp op <$> desugarTerm t
desugarTerm (ATBin _ op t1 t2) =
  desugarBOp (getType t1) op <$> desugarTerm t1 <*> desugarTerm t2
desugarTerm (ATList _ es) = do
  des <- mapM desugarTerm es
  return $ foldr (\x y -> CCons 1 [x, y]) (CCons 0 []) des
desugarTerm (ATLet _ t) =
  lunbind t $ \((x, unembed -> t1), t2) -> do
  dt1 <- desugarTerm t1
  dt2 <- desugarTerm t2
  return $ CLet (strictness (getType t1)) (bind (translate x, embed dt1) dt2)
desugarTerm (ATCase _ bs) = CCase <$> mapM desugarBranch bs
desugarTerm (ATAscr t _) = desugarTerm t
desugarTerm (ATSub _ t)  = desugarTerm t

-- | Desugar a unary operator application.
desugarUOp :: UOp -> Core -> Core
desugarUOp Neg  c = COp ONeg  [c]
desugarUOp Not  c = COp ONot  [c]
desugarUOp Fact c = COp OFact [c]

-- | Desugar a binary operator application.
desugarBOp :: Type -> BOp -> Core -> Core -> Core
desugarBOp _  Add     c1 c2 = COp OAdd [c1,c2]
desugarBOp _  Sub     c1 c2 = COp OAdd [c1, COp ONeg [c2]]
desugarBOp _  Mul     c1 c2 = COp OMul [c1, c2]
desugarBOp _  Div     c1 c2 = COp ODiv [c1, c2]
desugarBOp _  Exp     c1 c2 = COp OExp [c1, c2]
desugarBOp ty Eq      c1 c2 = COp (OEq ty) [c1, c2]
desugarBOp ty Neq     c1 c2 = COp ONot [COp (OEq ty) [c1, c2]]
desugarBOp ty Lt      c1 c2 = COp (OLt ty) [c1, c2]
desugarBOp ty Gt      c1 c2 = COp (OLt ty) [c2, c1]
desugarBOp ty Leq     c1 c2 = COp ONot [COp (OLt ty) [c2, c1]]
desugarBOp ty Geq     c1 c2 = COp ONot [COp (OLt ty) [c1, c2]]
desugarBOp _  And     c1 c2 = COp OAnd [c1, c2]
desugarBOp _  Or      c1 c2 = COp OOr  [c1, c2]
desugarBOp _  Mod     c1 c2 = COp OMod [c1, c2]
desugarBOp _  Divides c1 c2 = COp ODivides [c1, c2]
desugarBOp _  RelPm   c1 c2 = COp ORelPm [c1, c2]
desugarBOp _  Binom   c1 c2 = COp OBinom [c1, c2]
desugarBOp _  Cons    c1 c2 = CCons 1 [c1, c2]

-- | Desugar a branch.
desugarBranch :: ABranch -> DSM CBranch
desugarBranch b =
  lunbind b $ \(ags, at) -> do
  cgs <- desugarGuards ags
  c <- desugarTerm at
  return $ bind cgs c

-- | Desugar a list of guards.
desugarGuards :: AGuards -> DSM CGuards
desugarGuards AGEmpty = return CGEmpty
desugarGuards (AGCons (unrebind -> (ag, ags))) =
  case ag of

    -- Boolean guards are desugared to a pattern-match on @true@.
    AGIf (unembed -> at) -> do
      c <- desugarTerm at
      cgs <- desugarGuards ags
      return $ CGCons (rebind (embed c, CPCons (fromEnum True) []) cgs)
    AGWhen (unembed -> at) ap -> do
      c <- desugarTerm at
      cgs <- desugarGuards ags
      return $ CGCons (rebind (embed c, desugarPattern ap) cgs)

-- | Desugar a typed pattern.
desugarPattern :: APattern -> CPattern
desugarPattern (APVar _ x)      = CPVar (translate x)
desugarPattern (APWild _)       = CPWild
desugarPattern APUnit           = CPCons 0 []
desugarPattern (APBool b)       = CPCons (fromEnum b) []
desugarPattern (APPair _ p1 p2) = CPCons 0 [desugarPattern p1, desugarPattern p2]
desugarPattern (APInj _ s p)    = CPCons (fromEnum s) [desugarPattern p]
desugarPattern (APNat _ n)      = CPNum (n%1)
desugarPattern (APSucc _ p)     = CPSucc (desugarPattern p)
desugarPattern (APCons _ p1 p2) = CPCons 1 [desugarPattern p1, desugarPattern p2]
desugarPattern (APList _ ps)    = foldr (\p cp -> CPCons 1 [desugarPattern p, cp])
                                        (CPCons 0 [])
                                        ps
desugarPattern p@(APNeg {})     = CPArith $ desugarArithPattern p
desugarPattern p@(APArith {})   = CPArith $ desugarArithPattern p

-- | XXX
desugarArithPattern :: APattern -> CArithPat
desugarArithPattern (APVar ty x) = CAPVar ty (translate x)
desugarArithPattern (APNeg ty p) = CAPOp CPNeg 0 (desugarArithPattern p)
desugarArithPattern (PArith op p1 p2) =
  case (desugarArithPattern p1, desugarArithPattern p2) of
    (Right v1, Right v2) -> Right (interpOp op v1 v2)
    (Left p, Right v)    -> Left $ case op of
      PAdd -> CAPOp CPAdd v p
      PMul -> CAPOp CPMul v p
      PSub -> CAPOp CPAdd (negate v) p
      PDiv -> CAPOp CPMul (1/v) p
    (Right v, Left p)    -> Left $ case op of
      PAdd -> CAPOp CPAdd v p
      PMul -> CAPOp CPMul v p
      PSub -> CAPOp CPAdd v (CAPOp CPNeg 0 p)
      PDiv -> CAPOp CPRecip v p
    _ -> error "Impossible! Multiple variables in desugarArithPattern"
  where
    interpOp PAdd = (+)
    interpOp PMul = (*)
    interpOp PSub = (-)
    interpOp PDiv = (/)

desugarArithPattern p = error $ "Impossible!  Non-arith pattern in desugarArithPattern: " ++ show p
