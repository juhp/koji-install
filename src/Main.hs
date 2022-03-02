{-# LANGUAGE CPP #-}

-- SPDX-License-Identifier: BSD-3-Clause

module Main (main) where

import Data.List.Extra
import SimpleCmd
import SimpleCmdArgs

import Builds
import BuildlogSizes
import User
import Install
import qualified Paths_koji_tool
import Progress
import Tasks

main :: IO ()
main = do
  sysdisttag <- do
    dist <- cmd "rpm" ["--eval", "%{dist}"]
    return $ if dist == "%{dist}" then "" else dist
  simpleCmdArgs (Just Paths_koji_tool.version)
    "Query and track Koji tasks, and install rpms from Koji."
    "see https://github.com/juhp/koji-tool#readme" $
    subcommands
    [ Subcommand "install"
      "Install rpm packages directly from a Koji build task" $
      installCmd
      <$> switchWith 'n' "dry-run" "Don't actually download anything"
      <*> switchWith 'D' "debug" "More detailed output"
      <*> hubOpt
      <*> optional (strOptionWith 'P' "packages-url" "URL"
                    "KojiFiles packages url [default: Fedora]")
      <*> switchWith 'l' "list" "List builds"
      <*> switchWith 'L' "latest" "Latest build"
      <*> modeOpt
      <*> disttagOpt sysdisttag
      <*> (flagWith' ReqNVR 'R' "nvr" "Give an N-V-R instead of package name"
           <|> flagWith ReqName ReqNV 'V' "nv" "Give an N-V instead of package name")
      <*> some (strArg "PKG|NVR|TASKID...")

    , Subcommand "builds"
      "Query Koji builds (by default lists most recent builds)" $
      buildsCmd
      <$> hubOpt
      <*> optional userOpt
      <*> (flagWith' 1 'L' "latest" "Latest build" <|>
           optionalWith auto 'l' "limit" "INT" "Maximum number of builds to show [default: 10]" 10)
      <*> many (parseBuildState <$> strOptionWith 's' "state" "STATE" "Filter builds by state (building,complete,deleted,fail(ed),cancel(ed)")
      <*> optional (Before <$> strOptionWith 'B' "before" "TIMESTAMP" "Builds completed before timedate [default: now]" <|>
                    After <$> strOptionWith 'F' "from" "TIMESTAMP" "Builds completed after timedate")
      <*> (fmap normalizeBuildType <$> optional (strOptionWith 't' "type" "TYPE" ("Select builds by type: " ++ intercalate "," kojiBuildTypes)))
      <*> switchWith 'd' "details" "Show more details of builds"
      <*> switchWith 'D' "debug" "Pretty-print raw XML result"
      <*> (BuildBuild <$> strOptionWith 'b' "build" "BUILD" "Show build details"
           <|> BuildPackage <$> strOptionWith 'p' "package" "PKG" "Builds of package"
           <|> BuildPattern <$> strArg "NVRPATTERN"
           <|> pure BuildQuery)

    , Subcommand "tasks"
      "Query Koji tasks (by default lists most recent buildArch tasks)" $
      tasksCmd
      <$> hubOpt
      <*> optional userOpt
      <*> (flagWith' 1 'L' "latest" "Latest build or task" <|>
           optionalWith auto 'l' "limit" "INT" "Maximum number of tasks to show [default: 10]" 10)
      <*> many (parseTaskState <$> strOptionWith 's' "state" "STATE" "Filter tasks by state (open,close(d),cancel(ed),fail(ed),assigned,free)")
      <*> many (strOptionWith 'a' "arch" "ARCH" "Task arch")
      <*> optional (Before <$> strOptionWith 'B' "before" "TIMESTAMP" "Tasks completed before timedate [default: now]" <|>
                    After <$> strOptionWith 'F' "from" "TIMESTAMP" "Tasks completed after timedate")
      <*> (fmap normalizeMethod <$> optional (strOptionWith 'm' "method" "METHOD" ("Select tasks by method (default 'buildArch'): " ++ intercalate "," kojiMethods)))
      <*> switchWith 'd' "details" "Show more details of builds"
      <*> switchWith 'D' "debug" "Pretty-print raw XML result"
      -- FIXME error if integer (eg mistakenly taskid)
      <*> optional (TaskPackage <$> strOptionWith 'P' "only-package" "PKG" "Filter task results to specified package"
                   <|> TaskNVR <$> strOptionWith 'N' "only-nvr" "PREFIX" "Filter task results by NVR prefix")
      <*> switchWith 'T' "tail" "Fetch the tail of build.log"
      <*> (Task <$> optionWith auto 't' "task" "TASKID" "Show task"
           <|> Parent <$> optionWith auto 'c' "children" "TASKID" "List child tasks of parent"
           <|> Build <$> strOptionWith 'b' "build" "BUILD" "List child tasks of build"
           <|> Package <$> strOptionWith 'p' "package" "PKG" "Build tasks of package"
           <|> Pattern <$> strArg "NVRPATTERN"
           <|> pure TaskQuery)

    , Subcommand "progress"
      "Track running Koji tasks by buildlog size" $
      progressCmd
      <$> optionalWith auto 'i' "interval" "MINUTES" "Polling interval between updates (default 2 min)" 2
      <*> switchWith 'm' "modules" "Track module builds"
      <*> many (TaskId <$> argumentWith auto "TASKID")

    , Subcommand "buildlog-sizes" "Show buildlog sizes for nvr patterns" $
      buildlogSizesCmd <$> strArg "NVRPATTERN"
    ]
  where
    hubOpt = optional (strOptionWith 'H' "hub" "HUB"
                       ("KojiHub shortname or url (HUB = " ++
                        intercalate ", " knownHubs ++
                        ") [default: fedora]"))

    userOpt :: Parser UserOpt
    userOpt =
      User <$> strOptionWith 'u' "user" "USER" "Koji user"
      <|> flagWith' UserSelf 'M' "mine" "Your tasks (krb fasid)"

    modeOpt :: Parser Mode
    modeOpt =
      flagWith' All 'a' "all" "all subpackages" <|>
      flagWith' Ask 'A' "ask" "ask for each subpackge [default if not installed]" <|>
      pkgsReqOpts

    pkgsReqOpts = PkgsReq
      <$> many (strOptionWith 'p' "package" "SUBPKG" "Subpackage (glob) to install") <*> many (strOptionWith 'x' "exclude" "SUBPKG" "Subpackage (glob) not to install")

    disttagOpt :: String -> Parser String
    disttagOpt disttag = startingDot <$> strOptionalWith 'd' "disttag" "DISTTAG" ("Use a different disttag [default: " ++ disttag ++ "]") disttag

    startingDot cs =
      case cs of
        "" -> error' "empty disttag"
        (c:_) -> if c == '.' then cs else '.' : cs

    normalizeMethod :: String -> String
    normalizeMethod m =
      case elemIndex (lower m) (map lower kojiMethods) of
        Just i -> kojiMethods !! i
        Nothing -> error' $! "unknown method: " ++ m

    normalizeBuildType :: String -> String
    normalizeBuildType m =
      case elemIndex (lower m) (map lower kojiBuildTypes) of
        Just i -> kojiBuildTypes !! i
        Nothing -> error' $! "unknown build type: " ++ m
