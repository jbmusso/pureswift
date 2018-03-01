module PSWC where

import Prelude

import Control.Monad.Aff (Aff, Fiber, launchAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (CONSOLE, log)
import Control.Monad.Except (runExcept)
import CoreFn.FromJSON (moduleFromJSON)
import CoreFn.Module (Module(..))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldr, for_)
import Data.List (List(..), (:))
import Data.Maybe (Maybe(..), maybe)
import Data.Monoid (guard)
import Data.Newtype (unwrap)
import Data.Path.Pathy (Dir, DirName(DirName), Path, Rel, Sandboxed, currentDir, dir, dir', file, parseRelFile, printPath, runDirName, sandbox, (<.>), (</>))
import Data.String as S
import Data.Traversable (traverse)
import Data.Trie (Trie(..), fromPaths)
import Data.Trie as Trie
import Debug.Trace (trace)
import Node.Encoding (Encoding(..))
import Node.FS (FS)
import Node.FS.Aff (exists, readTextFile, readdir, stat)
import Node.FS.Stats (isDirectory)
import Node.Path (FilePath)
import PureSwift.AST (AccessMod(..), Decl(..), DeclMod(..), Ident(..))
import PureSwift.PrettyPrinter (prettyPrint)

type Effects eff =
  ( fs :: FS
  , console :: CONSOLE
  | eff
  )

dryRun :: forall eff. Trie -> Array String -> Eff (console :: CONSOLE | eff) Unit
dryRun (Trie trie) ffis = do
  for_ trie \(Trie.Path path) ->
    case Array.unsnoc path of
      Just { init, last } -> do
        log $ "// " <> Array.intercalate "." path <> "__Namespace.swift"
        let
          enum = Enum (AccessModifier Public : Nil) (Ident last) Nil
          decl = if Array.null init then enum else Extension (AccessModifier Public : Nil) (Ident $ Array.intercalate "." init) (enum : Nil)
        log $ prettyPrint decl <> "\n"
      Nothing -> pure unit
  log $ Array.intercalate "\n" ffis

toPaths :: forall eff. Array FilePath -> Aff (Effects eff) ({ moduleNamePaths :: Array Trie.Path, ffis :: Array String })
toPaths = foldr acc (pure { moduleNamePaths: [], ffis: [] })
  where
    acc
      :: String
      -> Aff (Effects eff) ({ moduleNamePaths :: Array Trie.Path, ffis :: Array String })
      -> Aff (Effects eff) ({ moduleNamePaths :: Array Trie.Path, ffis :: Array String })
    acc filename state = do
      { moduleNamePaths, ffis } <- state
      let
        moduleDir :: Path Rel Dir Sandboxed
        moduleDir = dir' outputDir </> dir filename

        hidden :: Boolean
        hidden = maybe false (S.singleton >>> (_ == ".")) $ S.charAt 0 filename

        when
          :: Boolean
          -> Aff (Effects eff) ({ moduleNamePaths :: Array Trie.Path, ffis :: Array String })
          -> Aff (Effects eff) ({ moduleNamePaths :: Array Trie.Path, ffis :: Array String })
        when true m = m
        when false _ = state

        whenM
          :: Aff (Effects eff) Boolean
          -> Aff (Effects eff) ({ moduleNamePaths :: Array Trie.Path, ffis :: Array String })
          -> Aff (Effects eff) ({ moduleNamePaths :: Array Trie.Path, ffis :: Array String })
        whenM mb m = do
          b <- mb
          when b m

      when (not hidden) do
        stat <- stat $ printPath moduleDir

        when (isDirectory stat) do
          let filepath = printPath $ moduleDir </> file "corefn.json"
          trace ("------") \_ ->
          trace ("filepath" <> show filepath) \_ ->

          whenM (exists filepath) do
            -- moduleNamePaths' <- moduleNamePaths
            coreFn <- readTextFile UTF8 filepath
            case runExcept (moduleFromJSON coreFn) of
              Left e ->
                -- trace ("Left: " <> show e) \_->
                state
              Right { module: (Module module_) } -> do
                -- trace ("Right: " <> show module_.moduleForeign) \_ ->
                let
                  { moduleForeign, moduleName } = module_
                  hasForeign = not Array.null moduleForeign
                  ffiPath = if hasForeign then map (_ <.> "swift") (sandbox currentDir =<< parseRelFile (unwrap module_.modulePath)) else Nothing
                  foo = trace ("ffiPath: " <> show (map printPath ffiPath)) \_ -> unit

                ffi <- traverse (printPath >>> readTextFile UTF8) ffiPath
                let bar = trace ("ffi: " <> show ffi) \_ -> unit

                let
                  moduleNamePath = Trie.Path $ map unwrap $ unwrap moduleName
                  foreignNamePaths = guard hasForeign [moduleNamePath <> Trie.Path ["_Foreign"]]
                  namePaths = [moduleNamePath] <> foreignNamePaths

                pure $
                  { moduleNamePaths: namePaths <> moduleNamePaths
                  , ffis: (maybe [] Array.singleton ffi) <> ffis
                  }

outputDir :: DirName
outputDir = DirName "output"

-- pulp build -- --dump-corefn
main :: forall eff. Eff (Effects eff) (Fiber (Effects eff) Unit)
main = launchAff do
  files <- readdir $ runDirName outputDir
  { moduleNamePaths, ffis } <- toPaths files
  let trie = fromPaths moduleNamePaths
  liftEff $ dryRun trie ffis
