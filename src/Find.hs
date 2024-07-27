{-# LANGUAGE CPP #-}

-- SPDX-License-Identifier: BSD-3-Clause

module Find (
  findCmd,
  wordsList
  )
where

import Data.Char ( isDigit, isAsciiLower, isAsciiUpper )
import Data.List.Extra ((\\), dropSuffix, isSuffixOf)
import Data.Maybe (listToMaybe)
import Distribution.Koji
    ( BuildState(BuildBuilding, BuildFailed, BuildComplete),
      TaskState(TaskOpen, TaskFailed, TaskClosed) )
import SimpleCmd (error', (+-+))

import qualified Builds
import Install (Select(PkgsReq))
import qualified Tasks
import User ( UserOpt(User, UserSelf) )

data Words = Mine | Limit | Failure | Complete | Current | Build | Detail
           | Install | Tail | NoTail | Hwinfo | Arch | Debug
  deriving (Enum,Bounded)

findWords :: Words -> [String]
findWords Mine = ["my","mine"]
findWords Limit = ["last","latest"]
findWords Failure = ["fail","failure","failed"]
findWords Complete = ["complete","completed","completion",
                       "close","closed",
                       "finish","finished"]
findWords Current = ["current","building","open"]
findWords Build = ["build","builds"]
findWords Detail = ["detail","details","detailed"]
findWords Install = ["install"]
findWords Tail = ["tail"]
findWords NoTail = ["notail"]
findWords Hwinfo = ["hwinfo"]
findWords Debug = ["debug", "dbg"]
findWords Arch = ["x86_64", "aarch64", "ppc64le", "s390x", "i686", "armv7hl"]

wordsList :: ([String] -> String) -> [String]
wordsList f =
  map (f . findWords) [minBound..] ++ ["PACKAGE","USER\\'s","LIMIT"]

allWords :: [String]
allWords = concatMap findWords [minBound..]

-- FIXME: time: today, yesterday, week
-- FIXME: methods
-- FIXME: mlt (or mlft)
-- FIXME: separate last and latest?
findCmd :: Maybe String -> [String] -> IO ()
findCmd _ [] = error' $ "find handles these words:\n\n" ++
                  unlines (wordsList unwords)
findCmd mhub args = do
  let user = if hasWord Mine
             then Just UserSelf
             else case filter ("'s" `isSuffixOf`) args of
                    [] -> Nothing
                    [users] -> Just $ User (dropSuffix "'s" users)
                    more -> error' $ "more than one user's given: " ++
                            unwords more
      archs = if hasWord Arch
              then filter (`elem` findWords Arch) args else []
      defaultlimit = Just $ if hasWord Limit then 1 else 10
      failure = hasWord Failure
      complete = hasWord Complete
      current = hasWord Current
      build = hasWord Build
      detail = hasWord Detail
      install = hasWord Install
      tail' = hasWord Tail
      notail = hasWord NoTail
      hwinfo = hasWord Hwinfo
      debug = hasWord Debug
      (limit,mpkg) =
        case removeUsers (args \\ allWords) of
          [] -> (defaultlimit, Nothing)
          (num:pkgs) | all isDigit num  && length pkgs < 2 ->
                       let number = read num
                       in if number < 1000
                       then (Just number, listToMaybe pkgs)
                       else error' $ "is" +-+ num +-+
                          "an id? Use 'tasks' command for very large limits"
          -- FIXME allow pattern?
          [pkg] | all isPkgNameChar pkg -> (defaultlimit, Just pkg)
          other ->
            error' $
            "you can only specify one package - too many unknown words: " ++
            unwords other
      installation = if install
                     then Just (PkgsReq [] [] [] [])
                     else Nothing
  if build
    then
    let states = [BuildFailed|failure] ++ [BuildComplete|complete] ++
                 [BuildBuilding|current]
        buildreq = maybe Builds.BuildQuery Builds.BuildPackage mpkg
        detailed = if detail then Just Builds.Detailed else Nothing
    in Builds.buildsCmd mhub user limit states Nothing (Just "rpm") detailed installation debug buildreq
    else
    let states = [TaskFailed|failure] ++ [TaskClosed|complete] ++
                 [TaskOpen|current]
        taskreq = maybe Tasks.TaskQuery Tasks.Package mpkg
    in Tasks.tasksCmd mhub (Tasks.QueryOpts user limit states archs Nothing Nothing debug Nothing) (if detail then Just Tasks.Detailed else Nothing) ((tail' || failure) && not notail) hwinfo Nothing installation taskreq
  where
    hasWord :: Words -> Bool
    hasWord word = any (`elem` findWords word) args

    removeUsers :: [String] -> [String]
    removeUsers = filter (not . ("'s" `isSuffixOf`))

-- [Char] generated by
-- sort . nub <$> cmd "dnf" ["repoquery", "--qf=%{name}", "*"]
-- "+-.0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz"
isPkgNameChar :: Char -> Bool
isPkgNameChar c =
  isAsciiLower c || isAsciiUpper c || c `elem` "-.+_" || isDigit c
