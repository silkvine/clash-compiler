{-|
  Copyright   :  (C) 2012-2016, University of Twente,
                     2016-2017, Myrtle Software Ltd,
                     2017     , QBayLogic, Google Inc.
  License     :  BSD2 (see the file LICENSE)
  Maintainer  :  Christiaan Baaij <christiaan.baaij@gmail.com>

  Module that connects all the parts of the Clash compiler library
-}

{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE TupleSections            #-}

module Clash.Driver where

import qualified Control.Concurrent.Supply        as Supply
import           Control.DeepSeq
import           Control.Exception                (tryJust, bracket)
import           Control.Lens                     (view, (^.), _4)
import           Control.Monad                    (guard, when, unless, foldM)
import           Control.Monad.Catch              (MonadMask)
import           Control.Monad.IO.Class           (MonadIO)
import           Control.Monad.State              (evalState, get)
import           Control.Monad.State.Strict       (State)
import           Data.Hashable                    (hash)
import           Data.HashMap.Strict              (HashMap)
import qualified Data.HashMap.Strict              as HashMap
import qualified Data.HashSet                     as HashSet
import           Data.IntMap                      (IntMap)
import           Data.List                        (intercalate)
import           Data.Maybe                       (fromMaybe)
import           Data.Semigroup.Monad
import qualified Data.Text
import           Data.Text.Lazy                   (Text)
import qualified Data.Text.Lazy                   as Text
import qualified Data.Text.Lazy.IO                as Text
import           Data.Text.Prettyprint.Doc        (pretty)
import           Data.Text.Prettyprint.Doc.Extra
  (Doc, LayoutOptions (..), PageWidth (..) , layoutPretty, renderLazy,
   renderOneLine)
import qualified Data.Time.Clock                  as Clock
import qualified Language.Haskell.Interpreter     as Hint
import qualified Language.Haskell.Interpreter.Unsafe as Hint
import qualified System.Directory                 as Directory
import           System.Environment               (getExecutablePath)
import           System.FilePath                  ((</>), (<.>))
import qualified System.FilePath                  as FilePath
import qualified System.IO                        as IO
import           System.IO.Error                  (isDoesNotExistError)
import           System.IO.Temp
  (getCanonicalTemporaryDirectory, withTempDirectory, createTempDirectory)
import qualified Text.PrettyPrint.ANSI.Leijen     as ANSI
import           Text.Trifecta.Result
  (Result(Success, Failure), _errDoc)
import           Text.Read                        (readMaybe)
import           SrcLoc                           (SrcSpan)
import           GHC.BasicTypes.Extra             ()

import           Clash.Annotations.Primitive
  (HDL (..))
import           Clash.Annotations.BitRepresentation.Internal
  (CustomReprs)
import           Clash.Annotations.TopEntity      (TopEntity (..))
import           Clash.Annotations.TopEntity.Extra ()
import           Clash.Backend
import           Clash.Core.Evaluator             (PrimEvaluator)
import           Clash.Core.Name                  (Name (..))
import           Clash.Core.Term                  (Term)
import           Clash.Core.Type                  (Type)
import           Clash.Core.TyCon                 (TyConMap, TyConName)
import           Clash.Core.Var                   (Id, varName)
import           Clash.Core.VarEnv                (emptyVarEnv)
import           Clash.Driver.Types
import           Clash.Netlist                    (genNetlist)
import           Clash.Netlist.Util               (genComponentName, genTopComponentName)
import           Clash.Netlist.BlackBox.Parser    (runParse)
import           Clash.Netlist.BlackBox.Types     (BlackBoxTemplate, BlackBoxFunction)
import           Clash.Netlist.Types
  (BlackBox (..), Component (..), Identifier, FilteredHWType, HWMap)
import           Clash.Normalize                  (checkNonRecursive, cleanupGraph,
                                                   normalize, runNormalization)
import           Clash.Normalize.Util             (callGraph)
import           Clash.Primitives.Types
import           Clash.Primitives.Util            (hashCompiledPrimMap)
import           Clash.Unique                     (keysUniqMap, lookupUniqMap')
import           Clash.Util                       (first, reportTimeDiff)

-- | Get modification data of current clash binary.
getClashModificationDate :: IO Clock.UTCTime
getClashModificationDate = Directory.getModificationTime =<< getExecutablePath

-- | Creates a directory for all Clash's temporary files
createTemporaryClashDirectory :: IO FilePath
createTemporaryClashDirectory = do
  tmp <- getCanonicalTemporaryDirectory
  createTempDirectory tmp "clash"

-- | Create a set of target HDL files for a set of functions
generateHDL
  :: forall backend . Backend backend
  => CustomReprs
  -> BindingMap
  -- ^ Set of functions
  -> Maybe backend
  -> CompiledPrimMap
  -- ^ Primitive / BlackBox Definitions
  -> TyConMap
  -- ^ TyCon cache
  -> IntMap TyConName
  -- ^ Tuple TyCon cache
  -> (CustomReprs -> TyConMap -> Type ->
      State HWMap (Maybe (Either String FilteredHWType)))
  -- ^ Hardcoded 'Type' -> 'HWType' translator
  -> PrimEvaluator
  -- ^ Hardcoded evaluator (delta-reduction)
  -> [( Id
      , Maybe TopEntity
      , Maybe Id
      )]
  -- ^ topEntity bndr
  -- + (maybe) TopEntity annotation
  -- + (maybe) testBench bndr
  -> ClashOpts
  -- ^ Debug information level for the normalization process
  -> (Clock.UTCTime,Clock.UTCTime)
  -> IO ()
generateHDL reprs bindingsMap hdlState primMap tcm tupTcm typeTrans eval
  topEntities opts (startTime,prepTime) = go prepTime HashMap.empty topEntities where

  go prevTime _ [] = putStrLn $ "Clash: Total compilation took " ++
                                reportTimeDiff prevTime startTime

  -- Process the next TopEntity
  go prevTime seen ((topEntity,annM,benchM):topEntities') = do
  let topEntityS = Data.Text.unpack (nameOcc (varName topEntity))
  putStrLn $ "Clash: Compiling " ++ topEntityS

  -- Some initial setup
  let modName1 = takeWhile (/= '.') topEntityS
      (modName,prefixM) = case opt_componentPrefix opts of
        Just p
          | not (null p) -> case annM of
            -- Prefix top names with 'p', prefix other with 'p_tname'
            Just ann ->
              let nm = p ++ ('_':t_name ann)
              in  (nm,(Just (Data.Text.pack p),Just (Data.Text.pack nm)))
            -- Prefix top names with 'p', prefix other with 'p'
            _ ->  (p ++ '_':modName1,(Just (Data.Text.pack p),Just (Data.Text.pack p)))
          | Just ann <- annM -> case hdlKind (undefined :: backend) of
              -- Prefix other with 't_name'
              VHDL -> (t_name ann,(Nothing,Just (Data.Text.pack (t_name ann))))
              _    -> (t_name ann,(Nothing,Nothing))
        _ -> case annM of
          Just ann -> case hdlKind (undefined :: backend) of
            VHDL -> (t_name ann, (Nothing,Nothing))
            -- Prefix other with 't_name'
            _    -> (t_name ann, (Nothing,Just (Data.Text.pack (t_name ann))))
          _ -> (modName1, (Nothing,Nothing))
      iw        = opt_intWidth opts
      hdlsyn    = opt_hdlSyn opts
      escpIds   = opt_escapedIds opts
      forceUnd  = opt_forceUndefined opts
      hdlState' = setModName (Data.Text.pack modName)
                $ fromMaybe (initBackend iw hdlsyn escpIds forceUnd :: backend) hdlState
      hdlDir    = fromMaybe "." (opt_hdlDir opts) </>
                        Clash.Backend.name hdlState' </>
                        takeWhile (/= '.') topEntityS
      mkId      = evalState mkIdentifier hdlState'
      extId     = evalState extendIdentifier hdlState'
      ite       = ifThenElseExpr hdlState'
      topNm     = genTopComponentName mkId prefixM annM topEntity
      topNmU    = Data.Text.unpack topNm

  unless (opt_cachehdl opts) $ putStrLn "Clash: Ignoring .manifest files"

  -- Calculate the hash over the callgraph and the topEntity annotation
  (sameTopHash,sameBenchHash,manifest) <- do
    clashModDate <- getClashModificationDate

    let primMapHash = hashCompiledPrimMap primMap

    let
      topHash =
        hash ( annM
             , primMapHash
             , show clashModDate
             , callGraphBindings bindingsMap topEntity
             )

    let
      benchHashM =
        case benchM of
          Nothing -> Nothing
          Just bench ->
            let terms = callGraphBindings bindingsMap bench in
            Just (hash (annM, primMapHash, show clashModDate, terms))

    let manifestI  = Manifest (topHash,benchHashM) [] [] [] [] []

    let
      manFile =
        case annM of
          Nothing -> hdlDir </> topNmU <.> "manifest"
          _       -> hdlDir </> topNmU </> topNmU <.> "manifest"

    manM <- if not (opt_cachehdl opts)
            then return Nothing -- ignore manifest file because -fclash-nocache
            else (>>= readMaybe) . either (const Nothing) Just <$>
              tryJust (guard . isDoesNotExistError) (readFile manFile)
    return (maybe (False,False,manifestI)
                  (\man -> (fst (manifestHash man) == topHash
                           ,snd (manifestHash man) == benchHashM
                           ,man {manifestHash = (topHash,benchHashM)}
                           ))
                  manM)

  (supplyN,supplyTB) <- Supply.splitSupply
                    . snd
                    . Supply.freshId
                   <$> Supply.newSupply
  let topEntityNames = map (\(x,_,_) -> x) topEntities

  (topTime,manifest',seen') <- if sameTopHash
    then do
      putStrLn ("Clash: Using cached result for: " ++ Data.Text.unpack (nameOcc (varName topEntity)))
      topTime <- Clock.getCurrentTime
      return (topTime,manifest,HashMap.unionWith max (HashMap.fromList (map (,0) (componentNames manifest))) seen)
    else do
      -- 1. Normalise topEntity
      let transformedBindings = normalizeEntity reprs bindingsMap primMap tcm tupTcm
                                  typeTrans eval topEntityNames opts supplyN
                                  topEntity

      normTime <- transformedBindings `deepseq` Clock.getCurrentTime
      let prepNormDiff = reportTimeDiff normTime prevTime
      putStrLn $ "Clash: Normalisation took " ++ prepNormDiff

      -- 2. Generate netlist for topEntity
      (netlist,seen') <-
        genNetlist False opts reprs transformedBindings topEntities primMap
                   tcm typeTrans iw mkId extId ite seen hdlDir prefixM topEntity

      netlistTime <- netlist `deepseq` Clock.getCurrentTime
      let normNetDiff = reportTimeDiff netlistTime normTime
      putStrLn $ "Clash: Netlist generation took " ++ normNetDiff

      -- 3. Generate topEntity wrapper
      let topComponent = view _4 . head $ filter (Data.Text.isSuffixOf topNm . componentName . view _4) netlist
          (hdlDocs,manifest',dfiles,mfiles)  = createHDL hdlState' (Data.Text.pack modName) seen' netlist topComponent
                                   (topNm, Right manifest)
          dir = hdlDir </> maybe "" (const modName) annM
      prepareDir (opt_cleanhdl opts) (extension hdlState') dir
      mapM_ (writeHDL dir) hdlDocs
      copyDataFiles (opt_importPaths opts) dir dfiles
      writeMemoryDataFiles dir mfiles

      topTime <- hdlDocs `seq` Clock.getCurrentTime
      return (topTime,manifest',seen')

  benchTime <- case benchM of
    Just tb | not sameBenchHash -> do
      putStrLn $ "Clash: Compiling " ++ Data.Text.unpack (nameOcc (varName tb))

      let modName'  = genComponentName HashMap.empty mkId prefixM tb
          hdlState2 = setModName modName' hdlState'

      -- 1. Normalise testBench
      let transformedBindings = normalizeEntity reprs bindingsMap primMap tcm tupTcm
                                  typeTrans eval topEntityNames opts supplyTB tb
      normTime <- transformedBindings `deepseq` Clock.getCurrentTime
      let prepNormDiff = reportTimeDiff normTime topTime
      putStrLn $ "Clash: Testbench normalisation took " ++ prepNormDiff

      -- 2. Generate netlist for topEntity
      (netlist,seen'') <-
        genNetlist True opts reprs transformedBindings topEntities primMap
                   tcm typeTrans iw mkId extId ite seen' hdlDir prefixM tb

      netlistTime <- netlist `deepseq` Clock.getCurrentTime
      let normNetDiff = reportTimeDiff netlistTime normTime
      putStrLn $ "Clash: Testbench netlist generation took " ++ normNetDiff

      -- 3. Write HDL
      let (hdlDocs,_,dfiles,mfiles) = createHDL hdlState2 modName' seen'' netlist undefined
                           (topNm, Left manifest')
          dir = hdlDir </> maybe "" t_name annM </> Data.Text.unpack modName'
      prepareDir (opt_cleanhdl opts) (extension hdlState2) dir
      writeHDL (hdlDir </> maybe "" t_name annM) (head hdlDocs)
      mapM_ (writeHDL dir) (tail hdlDocs)
      copyDataFiles (opt_importPaths opts) dir dfiles
      writeMemoryDataFiles dir mfiles

      hdlDocs `seq` Clock.getCurrentTime

    Just tb -> do
      let tb' = Data.Text.unpack (nameOcc (varName tb))
      putStrLn ("Clash: Compiling: " ++ tb')
      putStrLn ("Clash: Using cached result for: " ++ tb')
      return topTime

    Nothing -> return topTime

  go benchTime seen' topEntities'

-- | Interpret a specific function from a specific module. This action tries
-- two things:
--
--   1. Interpret without explicitly loading the module. This will succeed if
--      the module was already loaded through a package database (set using
--      'interpreterArgs').
--
--   2. If (1) fails, it does try to load it explicitly. If this also fails,
--      an error is returned.
--
loadImportAndInterpret
  :: (MonadIO m, MonadMask m)
  => [String]
  -- ^ Extra search path (usually passed as -i)
  -> [String]
  -- ^ Interpreter args
  -> String
  -- ^ The folder in which the GHC bootstrap libraries (base, containers, etc.)
  -- can be found
  -> Hint.ModuleName
  -- ^ Module function lives in
  -> String
  -- ^ Function name
  -> String
  -- ^ Type name ("BlackBoxFunction" or "TemplateFunction")
  -> m (Either Hint.InterpreterError a)
loadImportAndInterpret iPaths0 interpreterArgs topDir qualMod funcName typ = do
  -- Try to interpret function *without* loading module explicitly. If this
  -- succeeds, the module was already in the global package database(s).
  bbfE <- Hint.unsafeRunInterpreterWithArgsLibdir interpreterArgs topDir $ do
    iPaths1 <- (++iPaths0) <$> Hint.get Hint.searchPath
    Hint.set [Hint.searchPath Hint.:= iPaths1]
    Hint.setImports [ "Clash.Netlist.Types", "Clash.Netlist.BlackBox.Types", qualMod]
    Hint.unsafeInterpret funcName typ

  case bbfE of
    Left _ -> do
      -- Try to interpret module as a local module, not yet present in the
      -- global package database(s).
      Hint.unsafeRunInterpreterWithArgsLibdir interpreterArgs topDir $ do
        Hint.reset
        iPaths1 <- (iPaths0++) <$> Hint.get Hint.searchPath
        Hint.set [Hint.searchPath Hint.:= iPaths1]
        Hint.loadModules [qualMod]
        Hint.setImports [ "Clash.Netlist.BlackBox.Types", "Clash.Netlist.Types", qualMod]
        Hint.unsafeInterpret funcName typ
    Right _ -> do
      return bbfE

-- | Compiles blackbox functions and parses blackbox templates.
compilePrimitive
  :: [FilePath]
  -- ^ Import directories (-i flag)
  -> [FilePath]
  -- ^ Package databases
  -> FilePath
  -- ^ The folder in which the GHC bootstrap libraries (base, containers, etc.)
  -- can be found
  -> ResolvedPrimitive
  -- ^ Primitive to compile
  -> IO CompiledPrimitive
compilePrimitive idirs pkgDbs topDir (BlackBoxHaskell bbName wf bbGenName source) = do
  let interpreterArgs = concatMap (("-package-db":) . (:[])) pkgDbs
  -- Compile a blackbox template function or fetch it from an already compiled file.
  r <- go interpreterArgs source
  processHintError
    (show bbGenName)
    bbName
    (\bbFunc -> BlackBoxHaskell bbName wf bbGenName (hash source, bbFunc))
    r
  where
    qualMod = intercalate "." modNames
    BlackBoxFunctionName modNames funcName = bbGenName

    -- | Create directory based on base name and directory. Return path
    -- of directory just created.
    createDirectory'
      :: FilePath
      -> FilePath
      -> IO FilePath
    createDirectory' base sub =
      let new = base </> sub in
      Directory.createDirectory new >> return new

    go
      :: [String]
      -> Maybe Text
      -> IO (Either Hint.InterpreterError BlackBoxFunction)
    go args (Just source') = do
      -- Create a temporary directory with user module in it, add it to the
      -- list of import direcotries, and run as if it were a "normal" compiled
      -- module.
      tmpDir0 <- getCanonicalTemporaryDirectory
      withTempDirectory tmpDir0 "clash-prim-compile" $ \tmpDir1 -> do
        modDir <- foldM createDirectory' tmpDir1 (init modNames)
        Text.writeFile (modDir </> (last modNames ++ ".hs")) source'
        loadImportAndInterpret (tmpDir1:idirs) args topDir qualMod funcName "BlackBoxFunction"

    go args Nothing = do
      loadImportAndInterpret idirs args topDir qualMod funcName "BlackBoxFunction"

compilePrimitive idirs pkgDbs topDir (BlackBox pNm wf tkind () oReg libM imps incs templ) = do
  libM'  <- mapM parseTempl libM
  imps'  <- mapM parseTempl imps
  incs'  <- mapM (traverse parseBB) incs
  templ' <- parseBB templ
  return (BlackBox pNm wf tkind () oReg libM' imps' incs' templ')
 where
  iArgs = concatMap (("-package-db":) . (:[])) pkgDbs

  parseTempl
    :: Applicative m
    => Text
    -> m BlackBoxTemplate
  parseTempl t = case runParse t of
    Failure errInfo
      -> error (ANSI.displayS (ANSI.renderCompact (_errDoc errInfo)) "")
    Success t'
      -> pure t'

  parseBB
    :: ((TemplateFormat,BlackBoxFunctionName), Maybe Text)
    -> IO BlackBox
  parseBB ((TTemplate,_),Just t)     = BBTemplate <$> parseTempl t
  parseBB ((TTemplate,_),Nothing)    =
    error ("No template specified for blackbox: " ++ show pNm)
  parseBB ((THaskell,bbGenName),Just source) = do
    let BlackBoxFunctionName modNames funcName = bbGenName
        qualMod = intercalate "." modNames
    tmpDir <- getCanonicalTemporaryDirectory
    r <- withTempDirectory tmpDir "clash-prim-compile" $ \tmpDir' -> do
      let modDir = foldl (</>) tmpDir' (init modNames)
      Directory.createDirectoryIfMissing True modDir
      Text.writeFile (modDir </> last modNames <.>  "hs") source
      loadImportAndInterpret (tmpDir':idirs) iArgs topDir qualMod funcName "TemplateFunction"
    let hsh = hash (qualMod, source)
    processHintError (show bbGenName) pNm (BBFunction (Data.Text.unpack pNm) hsh) r
  parseBB ((THaskell,bbGenName),Nothing) = do
    let BlackBoxFunctionName modNames funcName = bbGenName
        qualMod = intercalate "." modNames
        hsh     = hash qualMod
    r <- loadImportAndInterpret idirs iArgs topDir qualMod funcName "TemplateFunction"
    processHintError (show bbGenName) pNm (BBFunction (Data.Text.unpack pNm) hsh) r

compilePrimitive _ _ _ (Primitive pNm wf typ) =
  return (Primitive pNm wf typ)

processHintError
  :: Monad m
  => String
  -> Data.Text.Text
  -> (t -> r)
  -> Either Hint.InterpreterError t
  -> m r
processHintError fun bb go r = case r of
  Left (Hint.GhcException err) ->
    error' "GHC Exception" err
  Left (Hint.NotAllowed err) ->
    error' "NotAllowed error" err
  Left (Hint.UnknownError err) ->
    error' "an unknown error" err
  Left (Hint.WontCompile ghcErrs) ->
    error' "compilation errors" (intercalate "\n\n" $ map Hint.errMsg ghcErrs)
  Right f ->
    return $ go f
 where
  error' errType report =
    error $ unwords [ "Encountered", errType, "while compiling blackbox template"
                    , "function", show fun, "for function", show bb ++ "."
                    , "Compilation reported: \n\n" ++ report ]

-- | Pretty print Components to HDL Documents
createHDL
  :: Backend backend
  => backend
  -- ^ Backend
  -> Identifier
  -- ^ Module hierarchy root
  -> HashMap Identifier Word
  -- ^ Component names
  -> [([Bool],SrcSpan,HashMap Identifier Word,Component)]
  -- ^ List of components
  -> Component
  -- ^ Top component
  -> (Identifier, Either Manifest Manifest)
  -- ^ Name of the manifest file
  -- + Either:
  --   * Left manifest:  Only write/update the hashes of the @manifest@
  --   * Right manifest: Update all fields of the @manifest@
  -> ([(String,Doc)],Manifest,[(String,FilePath)],[(String,String)])
  -- ^ The pretty-printed HDL documents
  -- + The update manifest file
  -- + The data files that need to be copied
createHDL backend modName seen components top (topName,manifestE) = flip evalState backend $ getMon $ do
  (hdlNmDocs,incs) <- unzip <$> mapM (\(_wereVoids,sp,ids,comp) -> genHDL modName sp (HashMap.unionWith max seen ids) comp) components
  hwtys <- HashSet.toList <$> extractTypes <$> Mon get
  typesPkg <- mkTyPackage modName hwtys
  dataFiles <- Mon getDataFiles
  memFiles  <- Mon getMemoryDataFiles
  let hdl   = map (first (<.> Clash.Backend.extension backend)) (typesPkg ++ hdlNmDocs)
      qincs = concat incs
      topFiles = hdl ++ qincs
  manifest <- either return (\m -> do
      let topInNames = map fst (inputs top)
      topInTypes  <- mapM (fmap (Text.toStrict . renderOneLine) .
                           hdlType (External topName) . snd) (inputs top)
      let topOutNames = map (fst . snd) (outputs top)
      topOutTypes <- mapM (fmap (Text.toStrict . renderOneLine) .
                           hdlType (External topName) . snd . snd) (outputs top)
      let compNames = map (componentName . view _4) components
      return (m { portInNames    = topInNames
                , portInTypes    = topInTypes
                , portOutNames   = topOutNames
                , portOutTypes   = topOutTypes
                , componentNames = compNames
                })
    ) manifestE
  let manDoc = ( Data.Text.unpack topName <.> "manifest"
               , pretty (Text.pack (show manifest)))
  return (manDoc:topFiles,manifest,dataFiles,memFiles)

-- | Prepares the directory for writing HDL files. This means creating the
--   dir if it does not exist and removing all existing .hdl files from it.
prepareDir :: Bool -- ^ Remove existing HDL files
           -> String -- ^ File extension of the HDL files.
           -> String
           -> IO ()
prepareDir cleanhdl ext dir = do
  -- Create the dir if needed
  Directory.createDirectoryIfMissing True dir
  -- Clean the directory when needed
  when cleanhdl $ do
    -- Find all HDL files in the directory
    files <- Directory.getDirectoryContents dir
    let to_remove = filter ((==ext) . FilePath.takeExtension) files
    -- Prepend the dirname to the filenames
    let abs_to_remove = map (FilePath.combine dir) to_remove
    -- Remove the files
    mapM_ Directory.removeFile abs_to_remove

-- | Writes a HDL file to the given directory
writeHDL :: FilePath -> (String, Doc) -> IO ()
writeHDL dir (cname, hdl) = do
  let rendered = renderLazy (layoutPretty (LayoutOptions (AvailablePerLine 120 0.4)) hdl)
      -- remove blank lines to keep things clean
      clean = Text.unlines
            . map (\t -> if Text.all (==' ') t then Text.empty else t)
            . Text.lines
  bracket (IO.openFile (dir </> cname) IO.WriteMode) IO.hClose $ \h -> do
    Text.hPutStr h (clean rendered)
    Text.hPutStr h (Text.pack "\n")

-- | Copy given files
writeMemoryDataFiles
    :: FilePath
    -- ^ Directory to copy  files to
    -> [(String, String)]
    -- ^ (filename, content)
    -> IO ()
writeMemoryDataFiles dir files =
    mapM_
      (uncurry writeFile)
      [(dir </> fname, content) | (fname, content) <- files]

copyDataFiles
    :: [FilePath]
    -> FilePath
    -> [(String,FilePath)]
    -> IO ()
copyDataFiles idirs dir = mapM_ (copyFile' idirs)
  where
    copyFile' dirs (nm,old) = do
      oldExists <- Directory.doesFileExist old
      if oldExists
        then Directory.copyFile old new
        else goImports dirs
      where
        new = dir FilePath.</> nm

        goImports [] = do
          oldExists <- Directory.doesFileExist old
          if oldExists
            then Directory.copyFile old new
            else unless (null old) (putStrLn ("WARNING: file " ++ show old ++ " does not exist"))
        goImports (d:ds) = do
          let old2 = d FilePath.</> old
          old2Exists <- Directory.doesFileExist old2
          if old2Exists
            then Directory.copyFile old2 new
            else goImports ds

-- | Get all the terms corresponding to a call graph
callGraphBindings
  :: BindingMap
  -- ^ All bindings
  -> Id
  -- ^ Root of the call graph
  -> [Term]
callGraphBindings bindingsMap tm =
  map ((^. _4) . (bindingsMap `lookupUniqMap'`)) (keysUniqMap cg)
  where
    cg = callGraph bindingsMap tm

-- | Normalize a complete hierarchy
normalizeEntity
  :: CustomReprs
  -> BindingMap
  -- ^ All bindings
  -> CompiledPrimMap
  -- ^ BlackBox HDL templates
  -> TyConMap
  -- ^ TyCon cache
  -> IntMap TyConName
  -- ^ Tuple TyCon cache
  -> (CustomReprs -> TyConMap -> Type ->
      State HWMap (Maybe (Either String FilteredHWType)))
  -- ^ Hardcoded 'Type' -> 'HWType' translator
  -> PrimEvaluator
  -- ^ Hardcoded evaluator (delta-reduction)
  -> [Id]
  -- ^ TopEntities
  -> ClashOpts
  -- ^ Debug information level for the normalization process
  -> Supply.Supply
  -- ^ Unique supply
  -> Id
  -- ^ root of the hierarchy
  -> BindingMap
normalizeEntity reprs bindingsMap primMap tcm tupTcm typeTrans eval topEntities
  opts supply tm = transformedBindings
  where
    doNorm = do norm <- normalize [tm]
                let normChecked = checkNonRecursive norm
                cleaned <- cleanupGraph tm normChecked
                return cleaned
    transformedBindings = runNormalization opts supply bindingsMap
                            typeTrans reprs tcm tupTcm eval primMap emptyVarEnv
                            topEntities doNorm
