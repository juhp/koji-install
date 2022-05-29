{-# LANGUAGE CPP #-}

-- SPDX-License-Identifier: BSD-3-Clause

module Builds (
  BuildReq(..),
  buildsCmd,
  parseBuildState,
  fedoraKojiHub,
  kojiBuildTypes,
  latestCmd
  )
where

import Control.Monad.Extra

import Data.Char (isDigit, toUpper)
import Data.List.Extra
import Data.Maybe
import Data.RPM.NVR
import Data.Time.Clock
import Data.Time.LocalTime
import Distribution.Koji
import Distribution.Koji.API
import SimpleCmd
import Text.Pretty.Simple

import Common
import qualified Tasks
import Time
import User
import Utils (buildOutputURL)

data BuildReq = BuildBuild String | BuildPackage String
              | BuildQuery | BuildPattern String
  deriving Eq

getTimedate :: Tasks.BeforeAfter -> String
getTimedate (Tasks.Before s) = s
getTimedate (Tasks.After s) = s

capitalize :: String -> String
capitalize "" = ""
capitalize (h:t) = toUpper h : t

-- FIXME show tail of build's build.log
buildsCmd :: Maybe String -> Maybe UserOpt -> Int -> [BuildState]
          -> Maybe Tasks.BeforeAfter -> Maybe String -> Bool -> Bool
          -> BuildReq -> IO ()
buildsCmd mhub museropt limit states mdate mtype details debug buildreq = do
  when (hub /= fedoraKojiHub && museropt == Just UserSelf) $
    error' "--mine currently only works with Fedora Koji: use --user instead"
  tz <- getCurrentTimeZone
  case buildreq of
    BuildBuild bld -> do
      when (isJust mdate) $
        error' "cannot use buildinfo together with timedate"
      let bldinfo = if all isDigit bld
                    then InfoID (read bld)
                    else InfoString bld
      mbld <- getBuild hub bldinfo
      whenJust (mbld >>= maybeBuildResult) $ printBuild hub tz
    BuildPackage pkg -> do
      when (head pkg == '-') $
        error' $ "bad combination: not a package: " ++ pkg
      when (isJust mdate) $
        error' "cannot use --package together with timedate"
      mpkgid <- getPackageID hub pkg
      case mpkgid of
        Nothing -> error' $ "no package id found for " ++ pkg
        Just pkgid -> do
          let fullquery = [("packageID", ValueInt pkgid),
                          commonBuildQueryOptions limit]
          when debug $ print fullquery
          builds <- listBuilds hub fullquery
          when debug $ mapM_ pPrintCompact builds
          if details || length builds == 1
            then mapM_ (printBuild hub tz) $ mapMaybe maybeBuildResult builds
            else mapM_ putStrLn $ mapMaybe (shortBuildResult tz) builds
    _ -> do
      query <- setupQuery
      let fullquery = query ++ [commonBuildQueryOptions limit]
      when debug $ print fullquery
      builds <- listBuilds hub fullquery
      when debug $ mapM_ pPrintCompact builds
      if details || length builds == 1
        then mapM_ (printBuild hub tz) $ mapMaybe maybeBuildResult builds
        else mapM_ putStrLn $ mapMaybe (shortBuildResult tz) builds
  where
    hub = maybe fedoraKojiHub hubURL mhub

    shortBuildResult :: TimeZone -> Struct -> Maybe String
    shortBuildResult tz bld = do
      nvr <- lookupStruct "nvr" bld
      state <- readBuildState <$> lookupStruct "state" bld
      let date =
            case lookupTime "completion" bld of
              Just t -> compactZonedTime tz t
              Nothing ->
                case lookupTime "start" bld of
                  Just t -> compactZonedTime tz t
                  Nothing -> ""
          mbid = lookupStruct "build_id" bld
      return $ nvr +-+ show state +-+ date +-+ maybe "" (buildinfoUrl hub) mbid

    setupQuery = do
      mdatestring <-
        case mdate of
          Nothing -> return Nothing
          Just date -> Just <$> cmd "date" ["+%F %T%z", "--date=" ++ dateString date]
      -- FIXME better output including user
      whenJust mdatestring $ \date ->
        putStrLn $ maybe "" show mdate +-+ date
      mowner <- maybeGetKojiUser hub museropt
      return $
        [("complete" ++ (capitalize . show) date, ValueString datestring) | Just date <- [mdate], Just datestring <- [mdatestring]]
        ++ [("userID", ValueInt (getID owner)) | Just owner <- [mowner]]
        ++ [("state", ValueArray (map buildStateToValue states)) | notNull states]
        ++ [("type", ValueString typ) | Just typ <- [mtype]]
        ++ case buildreq of
             BuildPattern pat -> [("pattern", ValueString pat)]
             _ -> []

    dateString :: Tasks.BeforeAfter -> String
    -- make time refer to past not future
    dateString beforeAfter =
      let timedate = getTimedate beforeAfter
      in case words timedate of
           [t] | t `elem` ["hour", "day", "week", "month", "year"] ->
                 "last " ++ t
           [t] | t `elem` ["today", "yesterday"] ->
                 t ++ " 00:00"
           [t] | any (lower t `isPrefixOf`) ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"] ->
                 "last " ++ t ++ " 00:00"
           [n,_unit] | all isDigit n -> timedate ++ " ago"
           _ -> timedate

    pPrintCompact =
#if MIN_VERSION_pretty_simple(4,0,0)
      pPrintOpt CheckColorTty
      (defaultOutputOptionsDarkBg {outputOptionsCompact = True})
#else
      pPrint
#endif

buildinfoUrl :: String -> Int -> String
buildinfoUrl hub bid =
  webUrl hub ++ "/buildinfo?buildID=" ++ show bid

-- FIXME
data BuildResult =
  BuildResult {buildNVR :: NVR,
               _buildState :: BuildState,
               _buildId :: Int,
               _mtaskId :: Maybe Int,
               _buildStartTime :: UTCTime,
               mbuildEndTime :: Maybe UTCTime
              }

maybeBuildResult :: Struct -> Maybe BuildResult
maybeBuildResult st = do
  start_time <- lookupTime "start" st
  let mend_time = lookupTime "completion" st
  buildid <- lookupStruct "build_id" st
  -- buildContainer has no task_id
  let mtaskid = lookupStruct "task_id" st
  state <- getBuildState st
  nvr <- lookupStruct "nvr" st >>= maybeNVR
  return $
    BuildResult nvr state buildid mtaskid start_time mend_time

printBuild :: String -> TimeZone -> BuildResult -> IO ()
printBuild hub tz build = do
  putStrLn ""
  let mendtime = mbuildEndTime build
  time <- maybe getCurrentTime return mendtime
  (mapM_ putStrLn . formatBuildResult hub (isJust mendtime) tz) (build {mbuildEndTime = Just time})
  putStrLn $ buildOutputURL hub $ buildNVR build

formatBuildResult :: String -> Bool -> TimeZone -> BuildResult -> [String]
formatBuildResult hub ended tz (BuildResult nvr state buildid mtaskid start mendtime) =
  [ showNVR nvr +-+ show state
  , buildinfoUrl hub buildid]
  ++ [Tasks.taskinfoUrl hub taskid | Just taskid <- [mtaskid]]
  ++ [formatLocalTime True tz start]
  ++
  case mendtime of
    Nothing -> []
    Just end ->
      [formatLocalTime False tz end | ended]
#if MIN_VERSION_time(1,9,1)
      ++
      let dur = diffUTCTime end start
      in [(if not ended then "current " else "") ++ "duration: " ++ renderDuration False dur]
#endif

#if !MIN_VERSION_koji(0,0,3)
buildStateToValue :: BuildState -> Value
buildStateToValue = ValueInt . fromEnum

parseBuildState :: String -> BuildState
parseBuildState s =
  case lower s of
    "building" -> BuildBuilding
    "complete" -> BuildComplete
    "deleted" -> BuildDeleted
    "fail" -> BuildFailed
    "failed" -> BuildFailed
    "cancel" -> BuildCanceled
    "canceled" -> BuildCanceled
    _ -> error' $! "unknown task state: " ++ s
#endif

getBuildState :: Struct -> Maybe BuildState
getBuildState st = readBuildState <$> lookup "state" st

kojiBuildTypes :: [String]
kojiBuildTypes = ["all", "image", "maven", "module", "rpm", "win"]

latestCmd :: Maybe String -> Bool -> String -> String -> IO ()
latestCmd mhub debug tag pkg = do
  let hub = maybe fedoraKojiHub hubURL mhub
  mbld <- kojiLatestBuild hub tag pkg
  when debug $ print mbld
  tz <- getCurrentTimeZone
  whenJust (mbld >>= maybeBuildResult) $ printBuild hub tz
