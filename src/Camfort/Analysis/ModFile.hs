{-# LANGUAGE RankNTypes #-}
{- |
Module      :  Camfort.Analysis.ModFile
Description :  CamFort-specific ModFiles helpers.
Copyright   :  (c) 2017, Dominic Orchard, Andrew Rice, Mistral Contrastin, Matthew Danish
License     :  Apache-2.0

Maintainer  :  dom.orchard@gmail.com
Stability   :  experimental
-}

module Camfort.Analysis.ModFile
  (
    -- * Getting mod files
    MFCompiler
  , genModFiles
  , getModFiles
  , readParseSrcDir
  , readParseSrcDirP
  , simpleCompiler
    -- * Using mod files
  , withCombinedModuleMap
  , withCombinedEnvironment
  , lookupUniqueName
  ) where

import           Control.Lens                       (ix, preview)
import           Control.Monad                      (forM)
import           Control.Monad.IO.Class
import qualified Data.ByteString                    as B
import qualified Data.ByteString.Lazy               as LB
import           Data.Char                          (toLower)
import           Data.Data                          (Data)
import           Data.List                          ((\\))
import qualified Data.Map                           as Map
import           Data.Maybe                         (catMaybes)
import           Data.Text.Encoding                 (decodeUtf8With, encodeUtf8)
import           Data.Text.Encoding.Error           (replace)
import           System.Directory                   (doesDirectoryExist,
                                                     listDirectory)
import           System.FilePath                    (takeExtension, (</>))


import qualified Language.Fortran.Analysis          as FA
import qualified Language.Fortran.Analysis.Renaming as FAR
import qualified Language.Fortran.Analysis.Types    as FAT
import qualified Language.Fortran.AST               as F
import qualified Language.Fortran.Parser.Any        as FP
import qualified Language.Fortran.Util.ModFile      as FM
import           Language.Fortran.ParserMonad       (FortranVersion(..))

import           Camfort.Analysis.Annotations       (A, unitAnnotation)
import           Camfort.Helpers

import           Pipes

--------------------------------------------------------------------------------
--  Getting mod files
--------------------------------------------------------------------------------

-- | Compiler for ModFile information, parameterised over an underlying monad
-- and the input to the compiler.
type MFCompiler r m = r -> FM.ModFiles -> F.ProgramFile A -> m FM.ModFile

-- | Compile the Modfile with only basic information.
simpleCompiler :: (Monad m) => MFCompiler () m
simpleCompiler () mfs = return . FM.genModFile . fst' . withCombinedEnvironment mfs
  where fst' (x, _, _) = x

genCModFile :: MFCompiler r m -> r -> FM.ModFiles -> F.ProgramFile A -> m FM.ModFile
genCModFile = id

-- | Generate a mode file based on the given mod file compiler
genModFiles
  :: (MonadIO m)
  => Maybe FortranVersion -> FM.ModFiles -> MFCompiler r m -> r -> FilePath -> [Filename] -> m FM.ModFiles
genModFiles mv mfs mfc env fp excludes = do
  fortranFiles <- liftIO $ fmap fst <$> readParseSrcDir mv mfs fp excludes
  traverse (genCModFile mfc env mfs) fortranFiles

-- | Retrieve the ModFiles under a given path.
getModFiles :: FilePath -> IO FM.ModFiles
getModFiles dir = do
  -- Figure out the camfort mod files and parse them.
  modFileNames <- (filter isModFile . map (dir </>)) <$> listDirectoryRecursively dir
  mods <- fmap concat . forM modFileNames $ \modFileName -> do
    modData <- LB.readFile modFileName
    let eResult = FM.decodeModFile modData
    case eResult of
      Left msg -> do
        putStrLn $ modFileName ++ ": Error: " ++ show msg
        pure []
      Right modFiles -> do
        pure modFiles
  putStrLn $ "Successfully parsed " ++ show (length mods) ++ " summary file(s)."
  pure mods

  where
    isModFile :: String -> Bool
    isModFile = (== FM.modFileSuffix) . takeExtension

listDirectoryRecursively :: FilePath -> IO [FilePath]
listDirectoryRecursively dir = listDirectoryRec dir ""
  where
    listDirectoryRec :: FilePath -> FilePath -> IO [FilePath]
    listDirectoryRec d f = do
      let fullPath = d </> f
      isDir <- doesDirectoryExist fullPath
      if isDir
      then do
        conts <- listDirectory fullPath
        concat <$> mapM (listDirectoryRec fullPath) conts
      else pure [fullPath]

readParseSrcDir :: Maybe FortranVersion
                -> FM.ModFiles
                -> FileOrDir
                -> [Filename]
                -> IO [(F.ProgramFile A, SourceText)]
readParseSrcDir mv mods inp excludes = do
  isdir <- isDirectory inp
  files <-
    if isdir
    then do
      files <- getFortranFiles inp
      -- Compute alternate list of excludes with the
      -- the directory appended
      let excludes' = excludes ++ map (\x -> inp </> x) excludes
      pure $ files \\ excludes'
    else pure [inp]
  mapMaybeM (readParseSrcFile mv mods) files
  where
    mapMaybeM :: Monad m => (a -> m (Maybe b)) -> [a] -> m [b]
    mapMaybeM f = fmap catMaybes . mapM f

readParseSrcDirP :: Maybe FortranVersion
                -> FM.ModFiles
                -> FileOrDir
                -> [Filename]
                -> Producer' (F.ProgramFile A, SourceText) IO ()
readParseSrcDirP mv mods inp excludes = do
  isdir <- liftIO $ isDirectory inp
  files <-
    if isdir
    then do
      files <- liftIO $ getFortranFiles inp
      -- Compute alternate list of excludes with the
      -- the directory appended
      let excludes' = excludes ++ map (\x -> inp </> x) excludes
      pure $ files \\ excludes'
    else pure [inp]
  for (each files) $ \ file -> do
    mProgSrc <- liftIO $ readParseSrcFile mv mods file
    case mProgSrc of
      Just progSrc -> yield progSrc
      Nothing -> pure ()
  pure ()

readParseSrcFile :: Maybe FortranVersion -> FM.ModFiles -> Filename -> IO (Maybe (F.ProgramFile A, SourceText))
readParseSrcFile mv mods f = do
  inp <- flexReadFile f
  let result = case mv of
        Nothing -> FP.fortranParserWithModFiles mods inp f
        Just v  -> FP.fortranParserWithModFilesAndVersion v mods inp f
  case result of
    Right ast -> pure $ Just (fmap (const unitAnnotation) ast, inp)
    Left  err -> print err >> pure Nothing
  where
    -- | Read file using ByteString library and deal with any weird characters.
    flexReadFile :: String -> IO B.ByteString
    flexReadFile = fmap (encodeUtf8 . decodeUtf8With (replace ' ')) . B.readFile

getFortranFiles :: FileOrDir -> IO [String]
getFortranFiles dir =
  filter isFortran <$> listDirectoryRecursively dir
  where
    -- | True if the file has a valid fortran extension.
    isFortran :: Filename -> Bool
    isFortran x = map toLower (takeExtension x) `elem` exts
      where exts = [".f", ".f90", ".f77", ".cmn", ".inc"]

--------------------------------------------------------------------------------
--  Using mod files
--------------------------------------------------------------------------------

-- | Normalize the 'ProgramFile' to include module map information from the
-- 'ModFiles'. Also return the module map, which links source names to unique
-- names within each program unit.
withCombinedModuleMap
  :: (Data a)
  => FM.ModFiles
  -> F.ProgramFile (FA.Analysis a)
  -> (F.ProgramFile (FA.Analysis a), FAR.ModuleMap)
withCombinedModuleMap mfs pf =
  let
    -- Use the module map derived from all of the included Camfort Mod files.
    mmap = FM.combinedModuleMap mfs
    tenv = FM.combinedTypeEnv mfs
    pfRenamed = FAR.analyseRenamesWithModuleMap mmap $ pf
  in (pfRenamed, mmap `Map.union` FM.extractModuleMap pfRenamed)

-- | Normalize the 'ProgramFile' to include environment information from
-- the 'ModFiles'. Also return the module map and type environment.
withCombinedEnvironment
  :: (Data a)
  => FM.ModFiles -> F.ProgramFile a -> (F.ProgramFile (FA.Analysis a), FAR.ModuleMap, FAT.TypeEnv)
withCombinedEnvironment mfs pf =
  let (pfRenamed, mmap) = withCombinedModuleMap mfs (FA.initAnalysis pf)
      moduleTEnv        = FM.combinedTypeEnv mfs
      (pf', tenv)       = FAT.analyseTypesWithEnv moduleTEnv $ pfRenamed
  in (pf', mmap, tenv)

-- | From a module map, look up the unique name associated with a given source
-- name in the given program unit. Also returns the name type, which tells you
-- whether the name belongs to a subprogram, variable or intrinsic.
lookupUniqueName :: F.ProgramUnitName -> F.Name -> FAR.ModuleMap -> Maybe (F.Name, FA.NameType)
lookupUniqueName puName srcName = preview $ ix puName . ix srcName
