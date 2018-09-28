{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE GADTs              #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections      #-}
{-# LANGUAGE ViewPatterns       #-}
-- | Parsing command line targets
--
-- There are two relevant data sources for performing this parsing:
-- the project configuration, and command line arguments. Project
-- configurations includes the resolver (defining a LoadedSnapshot of
-- global and snapshot packages), local dependencies, and project
-- packages. It also defines local flag overrides.
--
-- The command line arguments specify both additional local flag
-- overrides and targets in their raw form.
--
-- Flags are simple: we just combine CLI flags with config flags and
-- make one big map of flags, preferring CLI flags when present.
--
-- Raw targets can be a package name, a package name with component,
-- just a component, or a package name and version number. We first
-- must resolve these raw targets into both simple targets and
-- additional dependencies. This works as follows:
--
-- * If a component is specified, find a unique project package which
--   defines that component, and convert it into a name+component
--   target.
--
-- * Ensure that all name+component values refer to valid components
--   in the given project package.
--
-- * For names, check if the name is present in the snapshot, local
--   deps, or project packages. If it is not, then look up the most
--   recent version in the package index and convert to a
--   name+version.
--
-- * For name+version, first ensure that the name is not used by a
--   project package. Next, if that name+version is present in the
--   snapshot or local deps _and_ its location is PLIndex, we have the
--   package. Otherwise, add to local deps with the appropriate
--   PLIndex.
--
-- If in either of the last two bullets we added a package to local
-- deps, print a warning to the user recommending modifying the
-- extra-deps.
--
-- Combine the various 'ResolveResults's together into 'Target'
-- values, by combining various components for a single package and
-- ensuring that no conflicting statements were made about targets.
--
-- At this point, we now have a Map from package name to SimpleTarget,
-- and an updated Map of local dependencies. We still have the
-- aggregated flags, and the snapshot and project packages.
--
-- Finally, we upgrade the snapshot by using
-- calculatePackagePromotion.
module Stack.Build.Target
    ( -- * Types
      Target (..)
    , NeedTargets (..)
    , PackageType (..)
    , parseTargets
    , parseTargets'
      -- * Convenience helpers
    , gpdVersion
      -- * Test suite exports
    , parseRawTarget
    , RawTarget (..)
    , UnresolvedComponent (..)
    ) where

import           Stack.Prelude
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import           Distribution.PackageDescription (GenericPackageDescription)
import           Path
import           Path.Extra (rejectMissingDir)
import           Path.IO
import           Stack.Snapshot (calculatePackagePromotion)
import           Stack.SourceMap
import           Stack.Types.Config
import           Stack.Types.NamedComponent
import           Stack.Types.Build
import           Stack.Types.BuildPlan
import           Stack.Types.GhcPkgId
import           Stack.Types.SourceMap

-- | Do we need any targets? For example, `stack build` will fail if
-- no targets are provided.
data NeedTargets = NeedTargets | AllowNoTargets

---------------------------------------------------------------------------------
-- Get the RawInput
---------------------------------------------------------------------------------

-- | Raw target information passed on the command line.
newtype RawInput = RawInput { unRawInput :: Text }

getRawInput :: BuildOptsCLI -> Map PackageName ProjectPackage -> ([Text], [RawInput])
getRawInput boptscli locals =
    let textTargets' = boptsCLITargets boptscli
        textTargets =
            -- Handle the no targets case, which means we pass in the names of all project packages
            if null textTargets'
                then map (T.pack . packageNameString) (Map.keys locals)
                else textTargets'
     in (textTargets', map RawInput textTargets)

---------------------------------------------------------------------------------
-- Turn RawInput into RawTarget
---------------------------------------------------------------------------------

-- | The name of a component, which applies to executables, test
-- suites, and benchmarks
type ComponentName = Text

-- | Either a fully resolved component, or a component name that could be
-- either an executable, test, or benchmark
data UnresolvedComponent
    = ResolvedComponent !NamedComponent
    | UnresolvedComponent !ComponentName
    deriving (Show, Eq, Ord)

-- | Raw command line input, without checking against any databases or list of
-- locals. Does not deal with directories
data RawTarget
    = RTPackageComponent !PackageName !UnresolvedComponent
    | RTComponent !ComponentName
    | RTPackage !PackageName
    -- Explicitly _not_ supporting revisions on the command line. If
    -- you want that, you should be modifying your stack.yaml! (In
    -- fact, you should probably do that anyway, we're just letting
    -- people be lazy, since we're Haskeletors.)
    | RTPackageIdentifier !PackageIdentifier
  deriving (Show, Eq)

-- | Same as @parseRawTarget@, but also takes directories into account.
parseRawTargetDirs :: MonadIO m
                   => Path Abs Dir -- ^ current directory
                   -> Map PackageName ProjectPackage
                   -> RawInput -- ^ raw target information from the commandline
                   -> m (Either Text [(RawInput, RawTarget)])
parseRawTargetDirs root locals ri =
    case parseRawTarget t of
        Just rt -> return $ Right [(ri, rt)]
        Nothing -> do
            mdir <- liftIO $ forgivingAbsence (resolveDir root (T.unpack t))
              >>= rejectMissingDir
            case mdir of
                Nothing -> return $ Left $ "Directory not found: " `T.append` t
                Just dir ->
                    case mapMaybe (childOf dir) $ Map.toList locals of
                        [] -> return $ Left $
                            "No local directories found as children of " `T.append`
                            t
                        names -> return $ Right $ map ((ri, ) . RTPackage) names
  where
    childOf dir (name, pp) =
        if dir == ppRoot pp || isProperPrefixOf dir (ppRoot pp)
            then Just name
            else Nothing

    RawInput t = ri

-- | If this function returns @Nothing@, the input should be treated as a
-- directory.
parseRawTarget :: Text -> Maybe RawTarget
parseRawTarget t =
        (RTPackageIdentifier <$> parsePackageIdentifier s)
    <|> (RTPackage <$> parsePackageName s)
    <|> (RTComponent <$> T.stripPrefix ":" t)
    <|> parsePackageComponent
  where
    s = T.unpack t

    parsePackageComponent =
        case T.splitOn ":" t of
            [pname, "lib"]
                | Just pname' <- parsePackageName (T.unpack pname) ->
                    Just $ RTPackageComponent pname' $ ResolvedComponent CLib
            [pname, cname]
                | Just pname' <- parsePackageName (T.unpack pname) ->
                    Just $ RTPackageComponent pname' $ UnresolvedComponent cname
            [pname, typ, cname]
                | Just pname' <- parsePackageName (T.unpack pname)
                , Just wrapper <- parseCompType typ ->
                    Just $ RTPackageComponent pname' $ ResolvedComponent $ wrapper cname
            _ -> Nothing

    parseCompType t' =
        case t' of
            "exe" -> Just CExe
            "test" -> Just CTest
            "bench" -> Just CBench
            _ -> Nothing

---------------------------------------------------------------------------------
-- Resolve the raw targets
---------------------------------------------------------------------------------

data ResolveResult = ResolveResult
  { rrName :: !PackageName
  , rrRaw :: !RawInput
  , rrComponent :: !(Maybe NamedComponent)
  -- ^ Was a concrete component specified?
  , rrAddedDep :: !(Maybe PackageLocationImmutable)
  -- ^ Only if we're adding this as a dependency
  , rrPackageType :: !PackageType
  }

resolveRawTarget'
  :: forall env. HasEnvConfig env
  => (RawInput, RawTarget)
  -> RIO env (Either Text ResolveResult)
resolveRawTarget' x = do
  sma <- view $ envConfigL.to envConfigSMActual
  resolveRawTarget'' sma x

resolveRawTarget'' ::
       (HasLogFunc env, HasPantryConfig env)
    => SMActual
    -> (RawInput, RawTarget)
    -> RIO env (Either Text ResolveResult)
resolveRawTarget'' sma (ri, rt) =
  go rt
  where
    locals = smaProject sma
    deps = smaDeps sma
    globals = smaGlobal sma
    -- Helper function: check if a 'NamedComponent' matches the given 'ComponentName'
    isCompNamed :: ComponentName -> NamedComponent -> Bool
    isCompNamed _ CLib = False
    isCompNamed t1 (CInternalLib t2) = t1 == t2
    isCompNamed t1 (CExe t2) = t1 == t2
    isCompNamed t1 (CTest t2) = t1 == t2
    isCompNamed t1 (CBench t2) = t1 == t2

    go (RTComponent cname) = do
        -- Associated list from component name to package that defines
        -- it. We use an assoc list and not a Map so we can detect
        -- duplicates.
        allPairs <- fmap concat $ flip Map.traverseWithKey locals
          $ \name pp -> do
              comps <- ppComponents pp
              pure $ map (name, ) $ Set.toList comps
        pure $ case filter (isCompNamed cname . snd) allPairs of
                [] -> Left $ cname `T.append` " doesn't seem to be a local target. Run 'stack ide targets' for a list of available targets"
                [(name, comp)] -> Right ResolveResult
                  { rrName = name
                  , rrRaw = ri
                  , rrComponent = Just comp
                  , rrAddedDep = Nothing
                  , rrPackageType = PTProject
                  }
                matches -> Left $ T.concat
                    [ "Ambiugous component name "
                    , cname
                    , ", matches: "
                    , T.pack $ show matches
                    ]
    go (RTPackageComponent name ucomp) =
        case Map.lookup name locals of
            Nothing -> pure $ Left $ T.pack $ "Unknown local package: " ++ packageNameString name
            Just pp -> do
                comps <- ppComponents pp
                pure $ case ucomp of
                    ResolvedComponent comp
                        | comp `Set.member` comps -> Right ResolveResult
                            { rrName = name
                            , rrRaw = ri
                            , rrComponent = Just comp
                            , rrAddedDep = Nothing
                            , rrPackageType = PTProject
                            }
                        | otherwise -> Left $ T.pack $ concat
                            [ "Component "
                            , show comp
                            , " does not exist in package "
                            , packageNameString name
                            ]
                    UnresolvedComponent comp ->
                        case filter (isCompNamed comp) $ Set.toList comps of
                            [] -> Left $ T.concat
                                [ "Component "
                                , comp
                                , " does not exist in package "
                                , T.pack $ packageNameString name
                                ]
                            [x] -> Right ResolveResult
                              { rrName = name
                              , rrRaw = ri
                              , rrComponent = Just x
                              , rrAddedDep = Nothing
                              , rrPackageType = PTProject
                              }
                            matches -> Left $ T.concat
                                [ "Ambiguous component name "
                                , comp
                                , " for package "
                                , T.pack $ packageNameString name
                                , ": "
                                , T.pack $ show matches
                                ]

    go (RTPackage name)
      | Map.member name locals = return $ Right ResolveResult
          { rrName = name
          , rrRaw = ri
          , rrComponent = Nothing
          , rrAddedDep = Nothing
          , rrPackageType = PTProject
          }
      | Map.member name deps ||
        Map.member name globals = return $ Right ResolveResult
          { rrName = name
          , rrRaw = ri
          , rrComponent = Nothing
          , rrAddedDep = Nothing
          , rrPackageType = PTDependency
          }
      | otherwise = do
          mversion <- getLatestHackageVersion name UsePreferredVersions
          return $ case mversion of
            -- This is actually an error case. We _could_ return a
            -- Left value here, but it turns out to be better to defer
            -- this until the ConstructPlan phase, and let it complain
            -- about the missing package so that we get more errors
            -- together, plus the fancy colored output from that
            -- module.
            Nothing -> Right ResolveResult
              { rrName = name
              , rrRaw = ri
              , rrComponent = Nothing
              , rrAddedDep = Nothing
              , rrPackageType = PTDependency
              }
            Just pir -> Right ResolveResult
              { rrName = name
              , rrRaw = ri
              , rrComponent = Nothing
              , rrAddedDep = Just $ PLIHackage pir Nothing
              , rrPackageType = PTDependency
              }

    -- Note that we use CFILatest below, even though it's
    -- non-reproducible, to avoid user confusion. In any event,
    -- reproducible builds should be done by updating your config
    -- files!

    go (RTPackageIdentifier ident@(PackageIdentifier name version))
      | Map.member name locals = return $ Left $ T.concat
            [ tshow (packageNameString name)
            , " target has a specific version number, but it is a local package."
            , "\nTo avoid confusion, we will not install the specified version or build the local one."
            , "\nTo build the local package, specify the target without an explicit version."
            ]
      | otherwise = return $
          case Map.lookup name allLocs of
            -- Installing it from the package index, so we're cool
            -- with overriding it if necessary
            Just (PLImmutable (PLIHackage (PackageIdentifierRevision _name versionLoc _mcfi) _mtree)) -> Right ResolveResult
                  { rrName = name
                  , rrRaw = ri
                  , rrComponent = Nothing
                  , rrAddedDep =
                      if version == versionLoc
                        -- But no need to override anyway, this is already the
                        -- version we have
                        then Nothing
                        -- OK, we'll override it
                        else Just $ PLIHackage (PackageIdentifierRevision name version CFILatest) Nothing
                  , rrPackageType = PTDependency
                  }
            -- The package was coming from something besides the
            -- index, so refuse to do the override
            Just loc' -> Left $ T.concat
              [ "Package with identifier was targeted on the command line: "
              , T.pack $ packageIdentifierString ident
              , ", but it was specified from a non-index location: "
              , T.pack $ show loc'
              , ".\nRecommendation: add the correctly desired version to extra-deps."
              ]
            -- Not present at all, so add it
            Nothing -> Right ResolveResult
              { rrName = name
              , rrRaw = ri
              , rrComponent = Nothing
              , rrAddedDep = Just $ PLIHackage (PackageIdentifierRevision name version CFILatest) Nothing
              , rrPackageType = PTDependency
              }

      where
        allLocs :: Map PackageName PackageLocation
        allLocs = Map.unions
          [ Map.mapWithKey
              (\name' gp -> PLImmutable $ PLIHackage
                  (PackageIdentifierRevision name' (gpVersion gp) CFILatest)
                  Nothing)
              globals
          , Map.map dpLocation deps
          ]

-- | Convert a 'RawTarget' into a 'ResolveResult' (see description on
-- the module).
resolveRawTarget
  :: forall env. HasConfig env
  => Map PackageName (LoadedPackageInfo GhcPkgId) -- ^ globals
  -> Map PackageName (LoadedPackageInfo PackageLocation) -- ^ snapshot
  -> Map PackageName DepPackage -- ^ local deps
  -> Map PackageName ProjectPackage -- ^ project packages
  -> (RawInput, RawTarget)
  -> RIO env (Either Text ResolveResult)
resolveRawTarget globals snap deps locals (ri, rt) =
    go rt
  where
    -- Helper function: check if a 'NamedComponent' matches the given 'ComponentName'
    isCompNamed :: ComponentName -> NamedComponent -> Bool
    isCompNamed _ CLib = False
    isCompNamed t1 (CInternalLib t2) = t1 == t2
    isCompNamed t1 (CExe t2) = t1 == t2
    isCompNamed t1 (CTest t2) = t1 == t2
    isCompNamed t1 (CBench t2) = t1 == t2

    go (RTComponent cname) = do
        -- Associated list from component name to package that defines
        -- it. We use an assoc list and not a Map so we can detect
        -- duplicates.
        allPairs <- fmap concat $ flip Map.traverseWithKey locals
          $ \name pp -> do
              comps <- ppComponents pp
              pure $ map (name, ) $ Set.toList comps
        pure $ case filter (isCompNamed cname . snd) allPairs of
                [] -> Left $ cname `T.append` " doesn't seem to be a local target. Run 'stack ide targets' for a list of available targets"
                [(name, comp)] -> Right ResolveResult
                  { rrName = name
                  , rrRaw = ri
                  , rrComponent = Just comp
                  , rrAddedDep = Nothing
                  , rrPackageType = PTProject
                  }
                matches -> Left $ T.concat
                    [ "Ambiugous component name "
                    , cname
                    , ", matches: "
                    , T.pack $ show matches
                    ]
    go (RTPackageComponent name ucomp) =
        case Map.lookup name locals of
            Nothing -> pure $ Left $ T.pack $ "Unknown local package: " ++ packageNameString name
            Just pp -> do
                comps <- ppComponents pp
                pure $ case ucomp of
                    ResolvedComponent comp
                        | comp `Set.member` comps -> Right ResolveResult
                            { rrName = name
                            , rrRaw = ri
                            , rrComponent = Just comp
                            , rrAddedDep = Nothing
                            , rrPackageType = PTProject
                            }
                        | otherwise -> Left $ T.pack $ concat
                            [ "Component "
                            , show comp
                            , " does not exist in package "
                            , packageNameString name
                            ]
                    UnresolvedComponent comp ->
                        case filter (isCompNamed comp) $ Set.toList comps of
                            [] -> Left $ T.concat
                                [ "Component "
                                , comp
                                , " does not exist in package "
                                , T.pack $ packageNameString name
                                ]
                            [x] -> Right ResolveResult
                              { rrName = name
                              , rrRaw = ri
                              , rrComponent = Just x
                              , rrAddedDep = Nothing
                              , rrPackageType = PTProject
                              }
                            matches -> Left $ T.concat
                                [ "Ambiguous component name "
                                , comp
                                , " for package "
                                , T.pack $ packageNameString name
                                , ": "
                                , T.pack $ show matches
                                ]

    go (RTPackage name)
      | Map.member name locals = return $ Right ResolveResult
          { rrName = name
          , rrRaw = ri
          , rrComponent = Nothing
          , rrAddedDep = Nothing
          , rrPackageType = PTProject
          }
      | Map.member name deps ||
        Map.member name snap ||
        Map.member name globals = return $ Right ResolveResult
          { rrName = name
          , rrRaw = ri
          , rrComponent = Nothing
          , rrAddedDep = Nothing
          , rrPackageType = PTDependency
          }
      | otherwise = do
          mversion <- getLatestHackageVersion name UsePreferredVersions
          return $ case mversion of
            -- This is actually an error case. We _could_ return a
            -- Left value here, but it turns out to be better to defer
            -- this until the ConstructPlan phase, and let it complain
            -- about the missing package so that we get more errors
            -- together, plus the fancy colored output from that
            -- module.
            Nothing -> Right ResolveResult
              { rrName = name
              , rrRaw = ri
              , rrComponent = Nothing
              , rrAddedDep = Nothing
              , rrPackageType = PTDependency
              }
            Just pir -> Right ResolveResult
              { rrName = name
              , rrRaw = ri
              , rrComponent = Nothing
              , rrAddedDep = Just $ PLIHackage pir Nothing
              , rrPackageType = PTDependency
              }

    -- Note that we use CFILatest below, even though it's
    -- non-reproducible, to avoid user confusion. In any event,
    -- reproducible builds should be done by updating your config
    -- files!

    go (RTPackageIdentifier ident@(PackageIdentifier name version))
      | Map.member name locals = return $ Left $ T.concat
            [ tshow (packageNameString name)
            , " target has a specific version number, but it is a local package."
            , "\nTo avoid confusion, we will not install the specified version or build the local one."
            , "\nTo build the local package, specify the target without an explicit version."
            ]
      | otherwise = return $
          case Map.lookup name allLocs of
            -- Installing it from the package index, so we're cool
            -- with overriding it if necessary
            Just (PLImmutable (PLIHackage (PackageIdentifierRevision _name versionLoc _mcfi) _mtree)) -> Right ResolveResult
                  { rrName = name
                  , rrRaw = ri
                  , rrComponent = Nothing
                  , rrAddedDep =
                      if version == versionLoc
                        -- But no need to override anyway, this is already the
                        -- version we have
                        then Nothing
                        -- OK, we'll override it
                        else Just $ PLIHackage (PackageIdentifierRevision name version CFILatest) Nothing
                  , rrPackageType = PTDependency
                  }
            -- The package was coming from something besides the
            -- index, so refuse to do the override
            Just loc' -> Left $ T.concat
              [ "Package with identifier was targeted on the command line: "
              , T.pack $ packageIdentifierString ident
              , ", but it was specified from a non-index location: "
              , T.pack $ show loc'
              , ".\nRecommendation: add the correctly desired version to extra-deps."
              ]
            -- Not present at all, so add it
            Nothing -> Right ResolveResult
              { rrName = name
              , rrRaw = ri
              , rrComponent = Nothing
              , rrAddedDep = Just $ PLIHackage (PackageIdentifierRevision name version CFILatest) Nothing
              , rrPackageType = PTDependency
              }

      where
        allLocs :: Map PackageName PackageLocation
        allLocs = Map.unions
          [ Map.mapWithKey
              (\name' lpi -> PLImmutable $ PLIHackage
                  (PackageIdentifierRevision name' (lpiVersion lpi) CFILatest)
                  Nothing)
              globals
          , Map.map lpiLocation snap
          , Map.map dpLocation deps
          ]

---------------------------------------------------------------------------------
-- Combine the ResolveResults
---------------------------------------------------------------------------------

combineResolveResults
  :: forall env. HasLogFunc env
  => [ResolveResult]
  -> RIO env ([Text], Map PackageName Target, Map PackageName PackageLocationImmutable)
combineResolveResults results = do
    addedDeps <- fmap Map.unions $ forM results $ \result ->
      case rrAddedDep result of
        Nothing -> return Map.empty
        Just pl -> do
          return $ Map.singleton (rrName result) pl

    let m0 = Map.unionsWith (++) $ map (\rr -> Map.singleton (rrName rr) [rr]) results
        (errs, ms) = partitionEithers $ flip map (Map.toList m0) $ \(name, rrs) ->
            let mcomps = map rrComponent rrs in
            -- Confirm that there is either exactly 1 with no component, or
            -- that all rrs are components
            case rrs of
                [] -> assert False $ Left "Somehow got no rrComponent values, that can't happen"
                [rr] | isNothing (rrComponent rr) -> Right $ Map.singleton name $ TargetAll $ rrPackageType rr
                _
                  | all isJust mcomps -> Right $ Map.singleton name $ TargetComps $ Set.fromList $ catMaybes mcomps
                  | otherwise -> Left $ T.concat
                      [ "The package "
                      , T.pack $ packageNameString name
                      , " was specified in multiple, incompatible ways: "
                      , T.unwords $ map (unRawInput . rrRaw) rrs
                      ]

    return (errs, Map.unions ms, addedDeps)

---------------------------------------------------------------------------------
-- OK, let's do it!
---------------------------------------------------------------------------------

parseTargets' :: HasEnvConfig env
    => NeedTargets
    -> BuildOptsCLI
    -> RIO env SMTargets
parseTargets' needTargets boptscli = do
  logDebug "Parsing the targets"
  bconfig <- view buildConfigL
  sma <- view $ envConfigL.to envConfigSMActual
  workingDir <- getCurrentDir
  locals <- view $ buildConfigL.to (smwProject . bcSMWanted)
  let (textTargets', rawInput) = getRawInput boptscli locals

  (errs1, concat -> rawTargets) <- fmap partitionEithers $ forM rawInput $
    parseRawTargetDirs workingDir locals

  (errs2, resolveResults) <- fmap partitionEithers $ forM rawTargets $
    resolveRawTarget'

  (errs3, targets, addedDeps) <- combineResolveResults resolveResults

  case concat [errs1, errs2, errs3] of
    [] -> return ()
    errs -> throwIO $ TargetParseException errs

  case (Map.null targets, needTargets) of
    (False, _) -> return ()
    (True, AllowNoTargets) -> return ()
    (True, NeedTargets)
      | null textTargets' && bcImplicitGlobal bconfig -> throwIO $ TargetParseException
          ["The specified targets matched no packages.\nPerhaps you need to run 'stack init'?"]
      | null textTargets' && Map.null locals -> throwIO $ TargetParseException
          ["The project contains no local packages (packages not marked with 'extra-dep')"]
      | otherwise -> throwIO $ TargetParseException
          ["The specified targets matched no packages"]

  addedDeps' <- mapM (mkDepPackage . PLImmutable) addedDeps

  return SMTargets
    { smtTargets=targets
    , smtDeps=addedDeps' <> smaDeps sma
    }

parseTargets
    :: HasEnvConfig env
    => NeedTargets
    -> BuildOptsCLI
    -> RIO env
         ( LoadedSnapshot -- upgraded snapshot, with some packages possibly moved to local
         , Map PackageName (LoadedPackageInfo PackageLocation) -- all local deps
         , Map PackageName Target
         )
parseTargets needTargets boptscli = do
  logDebug "Parsing the targets"
  bconfig <- view buildConfigL
  ls0 <- view loadedSnapshotL
  workingDir <- getCurrentDir
  locals <- view $ buildConfigL.to (smwProject . bcSMWanted)
  deps <- view $ buildConfigL.to (smwDeps . bcSMWanted)
  let globals = lsGlobals ls0
      snap = lsPackages ls0
      (textTargets', rawInput) = getRawInput boptscli locals

  (errs1, concat -> rawTargets) <- fmap partitionEithers $ forM rawInput $
    parseRawTargetDirs workingDir locals

  (errs2, resolveResults) <- fmap partitionEithers $ forM rawTargets $
    resolveRawTarget globals snap deps locals

  (errs3, targets, addedDeps) <- combineResolveResults resolveResults

  case concat [errs1, errs2, errs3] of
    [] -> return ()
    errs -> throwIO $ TargetParseException errs

  case (Map.null targets, needTargets) of
    (False, _) -> return ()
    (True, AllowNoTargets) -> return ()
    (True, NeedTargets)
      | null textTargets' && bcImplicitGlobal bconfig -> throwIO $ TargetParseException
          ["The specified targets matched no packages.\nPerhaps you need to run 'stack init'?"]
      | null textTargets' && Map.null locals -> throwIO $ TargetParseException
          ["The project contains no local packages (packages not marked with 'extra-dep')"]
      | otherwise -> throwIO $ TargetParseException
          ["The specified targets matched no packages"]

  let flags = Map.unionWith Map.union
        (boptsCLIFlagsByName boptscli)
        (undefined "bcFlags bconfig")
      hides = Map.empty -- not supported to add hidden packages

      -- We promote packages to the local database if the GHC options
      -- are added to them by name. See:
      -- https://github.com/commercialhaskell/stack/issues/849#issuecomment-320892095.
      --
      -- GHC options applied to all packages are handled by getGhcOptions.
      options = configGhcOptionsByName (bcConfig bconfig)

      drops = Set.empty -- not supported to add drops

  (globals', snapshots, locals') <- do
    addedDeps' <- fmap Map.fromList $ forM (Map.toList addedDeps) $ \(name, loc) -> do
      gpd <- loadCabalFileImmutable loc
      return (name, (gpd, PLImmutable loc, Nothing))

    -- Calculate a list of all of the locals, based on the project
    -- packages, local dependencies, and added deps found from the
    -- command line
    projectPackages' <- for locals $ \pp -> do
      gpd <- ppGPD pp
      pure (gpd, PLMutable $ ppResolvedDir pp, Just pp)
    deps' <- for deps $ \dp -> do
      gpd <- liftIO $ cpGPD (dpCommon dp)
      pure (gpd, dpLocation dp, Nothing)
    let allLocals :: Map PackageName (GenericPackageDescription, PackageLocation, Maybe ProjectPackage)
        allLocals = Map.unions
          [ -- project packages
            projectPackages'
          , -- added deps take precendence over local deps
            addedDeps'
          , deps'
          ]

    calculatePackagePromotion
      ls0 (Map.elems allLocals)
      flags hides options drops

  let ls = LoadedSnapshot
        { lsCompilerVersion = lsCompilerVersion ls0
        , lsGlobals = globals'
        , lsPackages = snapshots
        }

      localDeps = Map.fromList $ flip mapMaybe (Map.toList locals') $ \(name, lpi) ->
        -- We want to ignore any project packages, but grab the local
        -- deps and upgraded snapshot deps
        case lpiLocation lpi of
          (_, Just (Just _localPackageView)) -> Nothing -- project package
          (loc, _) -> Just (name, lpi { lpiLocation = loc }) -- upgraded or local dep

  return (ls, localDeps, targets)
