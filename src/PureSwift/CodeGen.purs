module PureSwift.CodeGen
 ( moduleToSwift
 ) where

import Prelude

import CoreFn.Expr (Bind(..), Expr(Abs, Accessor, App, Case, Constructor, ObjectUpdate, Let, Var))
import CoreFn.Expr (Expr(Literal)) as CoreFn
import CoreFn.Ident (Ident(..)) as CoreFn
import CoreFn.Literal (Literal(..)) as CoreFn
import CoreFn.Module (Module(..))
import CoreFn.Names (ModuleName(..), Qualified(..))
import Data.Array (concat, intercalate)
import Data.Bifunctor (bimap)
import Data.Char (toCharCode)
import Data.Char.Unicode (isAlphaNum)
import Data.Either (either)
import Data.Foldable (elem, foldMap, foldr)
import Data.Int (decimal, toStringAs)
import Data.List (List(..), (:))
import Data.List as List
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Newtype (unwrap)
import Data.String (singleton, toCharArray)
import Data.Tuple (Tuple(..))
import PureSwift.AST (AccessMod(..), Attribute(..), Decl(..), DeclMod(..), Exp(..), FunctionTypeArg(..), Ident(..), Lit(..), Statement(..), Type(..))

moduleToSwift :: forall a. Module a -> Decl
moduleToSwift (Module mod) = TopLevel statements
  where
  decls :: List Decl
  decls = foldr (append <<< declToSwift) Nil (List.fromFoldable mod.moduleDecls)

  extension :: Decl
  extension = Extension (AccessModifier Public : Nil) (moduleNameToSwift mod.moduleName) decls

  statements :: List Statement
  statements = ( Declaration extension : Nil )

  moduleNameToSwift :: ModuleName -> Ident
  moduleNameToSwift (ModuleName mn) = Ident $ intercalate "." (unwrap <$> mn)

  declToSwift :: Bind a -> List Decl
  declToSwift (NonRec a i e) = List.singleton $ bindingToSwift (Tuple (Tuple a i) e)
  declToSwift (Rec bs) = bindingToSwift <$> List.fromFoldable bs

  removeAttributes :: FunctionTypeArg -> FunctionTypeArg
  removeAttributes (FunctionTypeArg e i _ t) = FunctionTypeArg e i Nil t

  removeBothArgLabels :: FunctionTypeArg -> FunctionTypeArg
  removeBothArgLabels (FunctionTypeArg _ _ as t) = FunctionTypeArg Nothing Nothing as t

  removeAllReturnTypeArgLabels :: FunctionTypeArg -> FunctionTypeArg
  removeAllReturnTypeArgLabels (FunctionTypeArg as e i r) = FunctionTypeArg as e i (removeAllArgLabels r)

  removeAllArgLabels :: Type -> Type
  removeAllArgLabels = case _ of
    (FunctionType as t) ->
      FunctionType (removeBothArgLabels <<< removeAllReturnTypeArgLabels <$> as) (removeAllArgLabels t)
    typ -> typ

  expToType' :: (Type -> Type) -> Exp -> Maybe Type
  expToType' f = case _ of
    (Closure as r _) -> Just $ f $ FunctionType as r
    (Literal l) -> litToType l
    _ -> Nothing

  expToType :: Exp -> Maybe Type
  expToType = expToType' id

  litToType :: Lit -> Maybe Type
  litToType = case _ of
    IntLit _ -> Just IntType
    FloatLit _ -> Just FloatType
    CharLit _ -> Just CharType
    StringLit _ -> Just StringType
    BooleanLit _ -> Just BoolType
    _ -> Nothing

  bindingToSwift :: Tuple (Tuple a CoreFn.Ident) (CoreFn.Expr a) -> Decl
  bindingToSwift (Tuple (Tuple _ ident) expr) =
    Constant (accessMod : Static : Nil) (identToSwift ident) (expToType' removeAllArgLabels exp) exp
    where
    accessMod :: DeclMod
    accessMod = AccessModifier $ if isExported ident then Public else Internal

    isExported :: CoreFn.Ident -> Boolean
    isExported i = elem i mod.moduleExports

    exp :: Exp
    exp = exprToSwift expr

  identToSwift :: CoreFn.Ident -> Ident
  identToSwift (CoreFn.Ident ident) = Ident $ properToSwift ident
  identToSwift (CoreFn.GenIdent s i) = Ident $ fromMaybe "" s <> toStringAs decimal i -- FIXME
  identToSwift CoreFn.UnusedIdent = Ident "/* FIXME: UnusedIdent */"

  properToSwift :: String -> String
  properToSwift name
    | nameIsSwiftReserved name = "`" <> name <> "`"
    | otherwise = foldMap identCharToString $ toCharArray name

  -- | Attempts to find a human-readable name for a symbol, if none has been
  -- | specified returns the ordinal value.
  identCharToString :: Char -> String
  identCharToString c | isAlphaNum c = singleton c
  identCharToString '_' = "_"
  identCharToString '.' = "$dot"
  identCharToString '$' = "$dollar"
  identCharToString '~' = "$tilde"
  identCharToString '=' = "$eq"
  identCharToString '<' = "$less"
  identCharToString '>' = "$greater"
  identCharToString '!' = "$bang"
  identCharToString '#' = "$hash"
  identCharToString '%' = "$percent"
  identCharToString '^' = "$up"
  identCharToString '&' = "$amp"
  identCharToString '|' = "$bar"
  identCharToString '*' = "$times"
  identCharToString '/' = "$div"
  identCharToString '+' = "$plus"
  identCharToString '-' = "$minus"
  identCharToString ':' = "$colon"
  identCharToString '\\' = "$bslash"
  identCharToString '?' = "$qmark"
  identCharToString '@' = "$at"
  identCharToString '\'' = "$prime"
  identCharToString c = "$" <> (toStringAs decimal $ toCharCode c)

  -- | Checks whether an identifier name is reserved in Swift.
  nameIsSwiftReserved :: String -> Boolean
  nameIsSwiftReserved name = name `elem` swiftAnyReserved

  swiftAnyReserved :: Array String
  swiftAnyReserved =
    concat
      [ swiftDeclKeywords
      , swiftStatementKeywords
      , swiftExprTypeKeywords
      , swiftPatternKeywords
      , swiftNumberSignKeywords
      , swiftContextualKeywords
      ]

  swiftDeclKeywords :: Array String
  swiftDeclKeywords =
    [ "associatedtype"
    , "class"
    , "deinit"
    , "enum"
    , "extension"
    , "fileprivate"
    , "func"
    , "import"
    , "init"
    , "inout"
    , "internal"
    , "let"
    , "open"
    , "operator"
    , "private"
    , "protocol"
    , "public"
    , "static"
    , "struct"
    , "subscript"
    , "typealias"
    , "var"
    ]

  swiftStatementKeywords :: Array String
  swiftStatementKeywords =
    [ "break"
    , "case"
    , "continue"
    , "default"
    , "defer"
    , "do"
    , "else"
    , "fallthrough"
    , "for"
    , "guard"
    , "if"
    , "in"
    , "repeat"
    , "return"
    , "switch"
    , "where"
    , "while"
    ]

  swiftExprTypeKeywords :: Array String
  swiftExprTypeKeywords =
    [ "as"
    , "Any"
    , "catch"
    , "false"
    , "is"
    , "nil"
    , "rethrows"
    , "super"
    , "self"
    , "Self"
    , "throw"
    , "throws"
    , "true"
    , "try"
    ]

  swiftPatternKeywords :: Array String
  swiftPatternKeywords =
    [ "_"
    ]

  swiftNumberSignKeywords :: Array String
  swiftNumberSignKeywords =
    [ "#available"
    , "#colorLiteral"
    , "#column"
    , "#else"
    , "#elseif"
    , "#endif"
    , "#file"
    , "#fileLiteral"
    , "#function"
    , "#if"
    , "#imageLiteral"
    , "#line"
    , "#selector"
    , "#sourceLocation"
    ]

  swiftContextualKeywords :: Array String
  swiftContextualKeywords =
    [ "associativity"
    , "convenience"
    , "dynamic"
    , "didSet"
    , "final"
    , "get"
    , "infix"
    , "indirect"
    , "lazy"
    , "left"
    , "mutating"
    , "none"
    , "nonmutating"
    , "optional"
    , "override"
    , "postfix"
    , "precedence"
    , "prefix"
    , "Protocol"
    , "required"
    , "right"
    , "set"
    , "Type"
    , "unowned"
    , "weak"
    , "willSet"
    ]

  exprToSwift :: CoreFn.Expr a -> Exp
  exprToSwift (CoreFn.Literal _ l) = Literal $ literalToSwift l
  exprToSwift (Constructor _ tn cn fs) = Literal $ StringLit "/* FIXME: Constructor Exp */"
  exprToSwift (Accessor _ s e) = Literal $ StringLit "/* FIXME: Accessor Exp */"
  exprToSwift (ObjectUpdate _ e ts) = Literal $ StringLit "/* FIXME: ObjectUpdate Exp */"
  exprToSwift (Abs _ i e) = Closure args returnType ss
    where
    exp :: Exp
    exp = exprToSwift e

    atts :: List Attribute
    atts = case exp of
      Closure _ _ _ -> Escaping : Nil
      _ -> Nil

    returnType :: Type
    returnType = fromMaybe AnyType $ expToType exp

    args :: List FunctionTypeArg
    args =
      ( FunctionTypeArg (Just $ Ident "_") (Just $ identToSwift i) atts returnType
      : Nil
      )

    ss :: List Statement
    ss =
      ( Return (Just exp)
      : Nil
      )
  exprToSwift (App _ e1 e2) = FunctionCall (exprToSwift e1) (exprToSwift e2 : Nil)
  exprToSwift (Var _ q) = qualifiedToSwift q
  exprToSwift (Case _ es cs) = Literal $ StringLit "/* FIXME: Case Exp */"
  exprToSwift (Let _ bs e) = Literal $ StringLit "/* FIXME: Let Exp */"

  literalToSwift :: CoreFn.Literal (Expr a) -> Lit
  literalToSwift (CoreFn.NumericLiteral x) = either IntLit FloatLit x
  literalToSwift (CoreFn.StringLiteral x) = StringLit x
  literalToSwift (CoreFn.CharLiteral x) = CharLit x
  literalToSwift (CoreFn.BooleanLiteral x) = BooleanLit x
  literalToSwift (CoreFn.ArrayLiteral xs) = ArrayLit $ exprToSwift <$> List.fromFoldable xs
  literalToSwift (CoreFn.ObjectLiteral xs) = DictLit $ Map.fromFoldable $ map (bimap (Literal <<< StringLit) exprToSwift) xs

  qualifiedToSwift (Qualified q i) =
    case q of
      Just m -> ExplicitMember (Identifier $ moduleNameToSwift m) ident
      Nothing -> Identifier ident
    where
      ident = identToSwift i
