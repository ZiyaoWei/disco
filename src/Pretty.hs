{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE ViewPatterns              #-}

module Pretty where

import           Control.Applicative     hiding (empty)
import           Control.Monad.Reader
import           Data.Char               (toLower)
import           Data.List               (findIndex)
import           Data.Maybe              (fromJust)

import qualified Parser                  as PR
import           Types

import qualified Text.PrettyPrint        as PP
import           Unbound.LocallyNameless (LFreshM, Name, bind, embed, lunbind,
                                          rec, runLFreshM, string2Name, unembed,
                                          unrec)

--------------------------------------------------
-- Monadic pretty-printing

hsep ds  = PP.hsep <$> sequence ds
parens   = fmap PP.parens
text     = return . PP.text
integer  = return . PP.integer
nest n d = PP.nest n <$> d
empty    = return PP.empty

(<+>) = liftA2 (PP.<+>)
(<>)  = liftA2 (PP.<>)
($+$) = liftA2 (PP.$+$)

--------------------------------------------------
-- Precedence and associativity

type Prec = Int
data Assoc = AL | AR | AN
  deriving (Show, Eq)

prec :: BOp -> Prec
prec op = fromJust . findIndex (op `elem`) $
  [ []
  , []
  , [ Or ]
  , [ And ]
  , [ Equals, Less ]
  , []
  , [ Add, Sub ]
  , [ Mul, Div ]
  ]

assoc :: BOp -> Assoc
assoc op
  | op `elem` [Add, Sub, Mul, Div] = AL
  | op `elem` [And, Or]            = AR
  | otherwise                      = AN

pa :: BOp -> PA
pa op = PA (prec op) (assoc op)

data PA = PA Prec Assoc
  deriving (Show, Eq)

instance Ord PA where
  compare (PA p1 a1) (PA p2 a2) = compare p1 p2 `mappend` (if a1 == a2 then EQ else LT)

initPA :: PA
initPA = PA 0 AL

funPA :: PA
funPA = PA 10 AL

arrPA :: PA
arrPA = PA 1 AR

type Doc = ReaderT PA LFreshM PP.Doc

--------------------------------------------------

prettyTy :: Type -> Doc
prettyTy TyVoid           = text "Void"
prettyTy TyUnit           = text "Unit"
prettyTy TyBool           = text "Bool"
prettyTy (TyArr ty1 ty2)  = mparens arrPA $
  prettyTy' 1 AL ty1 <+> text "->" <+> prettyTy' 1 AR ty2
prettyTy (TyPair ty1 ty2) = mparens (PA 7 AR) $
  prettyTy' 7 AL ty1 <+> text "*" <+> prettyTy' 7 AR ty2
prettyTy (TySum  ty1 ty2) = mparens (PA 6 AR) $
  prettyTy' 6 AL ty1 <+> text "+" <+> prettyTy' 6 AR ty2
prettyTy TyN              = text "N"
prettyTy TyZ              = text "Z"
prettyTy TyQ              = text "Q"

prettyTy' p a t = local (const (PA p a)) (prettyTy t)

--------------------------------------------------

mparens :: PA -> Doc -> Doc
mparens pa doc = do
  parentPA <- ask
  (if (pa < parentPA) then parens else id) doc

prettyName :: Name Term -> Doc
prettyName = text . show

prettyTerm :: Term -> Doc
prettyTerm (TVar x)      = prettyName x
prettyTerm TUnit         = text "()"
prettyTerm (TBool b)     = text (map toLower $ show b)
prettyTerm (TAbs bnd)    = mparens initPA $
  lunbind bnd $ \(x,body) ->
  hsep [prettyName x, text "↦", prettyTerm' 0 AL body]
prettyTerm (TJuxt t1 t2) = mparens funPA $
  prettyTerm' 10 AL t1 <+> prettyTerm' 10 AR t2
prettyTerm (TPair t1 t2) =
  parens (prettyTerm' 0 AL t1 <> text "," <+> prettyTerm' 0 AL t2)
prettyTerm (TInj side t) = mparens funPA $
  prettySide side <+> prettyTerm' 10 AR t
prettyTerm (TNat n)      = integer n
prettyTerm (TUn op t)    = prettyUOp op <> prettyTerm' 11 AL t
prettyTerm (TBin op t1 t2) = mparens (pa op) $
  hsep
  [ prettyTerm' (prec op) AL t1
  , prettyBOp op
  , prettyTerm' (prec op) AR t2
  ]
prettyTerm (TLet bnd) = mparens initPA $
  lunbind bnd $ \((x, unembed -> t1), t2) ->
  hsep
    [ text "let"
    , prettyName x
    , text "="
    , prettyTerm' 0 AL t1
    , text "in"
    , prettyTerm' 0 AL t2
    ]
prettyTerm (TCase b)    = text "case" $+$ nest 2 (prettyBranches b)
prettyTerm (TAscr t ty) = parens (prettyTerm t <+> text ":" <+> prettyTy ty)

prettyTerm' p a t = local (const (PA p a)) (prettyTerm t)

prettySide :: Side -> Doc
prettySide L = text "inl"
prettySide R = text "inr"

prettyUOp :: UOp -> Doc
prettyUOp Neg = text "-"

prettyBOp :: BOp -> Doc
prettyBOp Add    = text "+"
prettyBOp Sub    = text "-"
prettyBOp Mul    = text "*"
prettyBOp Div    = text "/"
prettyBOp Equals = text "=="
prettyBOp Less   = text "<"
prettyBOp And    = text "&&"
prettyBOp Or     = text "||"

prettyBranches :: [Branch] -> Doc
prettyBranches [] = error "Empty branches are disallowed."
prettyBranches bs = foldr ($+$) empty (map prettyBranch bs)

prettyBranch :: Branch -> Doc
prettyBranch br = lunbind br $ (\(gs,t) -> text "{" <+> prettyTerm t <+> prettyGuards gs)

prettyGuards :: [Guard] -> Doc
prettyGuards [] = text "otherwise"
prettyGuards gs = foldr (\g r -> prettyGuard g <+> r) (text "") gs

prettyGuard :: Guard -> Doc
prettyGuard (GIf et) = text "if" <+> (prettyTerm (unembed et))
prettyGuard (GWhen et p) = text "when" <+> prettyTerm (unembed et) <+> text "=" <+> prettyPattern p

prettyPattern :: Pattern -> Doc
prettyPattern (PVar x) = prettyName x
prettyPattern PWild = text "_"
prettyPattern PUnit = text "()"
prettyPattern (PBool b) = text $ map toLower $ show b
prettyPattern (PPair p1 p2) = parens $ prettyPattern p1 <> text "," <+> prettyPattern p2
prettyPattern (PInj s p) = prettySide s <+> prettyPattern p
prettyPattern (PNat n) = integer n
prettyPattern (PSucc p) = text "S" <+> prettyPattern p

renderDoc :: Doc -> String
renderDoc = PP.render . runLFreshM . flip runReaderT initPA

echoTerm :: String -> String
echoTerm = renderDoc . prettyTerm . PR.parseTermStr

echoTermP :: String -> IO ()
echoTermP = putStrLn . echoTerm

echoType :: String -> String
echoType = renderDoc . prettyTy . PR.parseTypeStr
