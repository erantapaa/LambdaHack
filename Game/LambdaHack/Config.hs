module Game.LambdaHack.Config
  ( CP, mkConfig, getOption, getItems, get, getFile, appDataDir, set, dump
  ) where

import System.Directory
import System.FilePath
import System.Environment
import qualified Data.ConfigFile as CF
import qualified Data.Binary as Binary
import qualified Data.Char as Char
import qualified Data.List as L

newtype CP = CP CF.ConfigParser

instance Binary.Binary CP where
  put (CP conf) = Binary.put $ CF.to_string conf
  get = do
    string <- Binary.get
    let c = CF.readstring CF.emptyCP string
    return $ toCP $ forceEither c

instance Show CP where
  show (CP conf) = show $ CF.to_string conf

forceEither :: Show a => Either a b -> b
forceEither (Left a)  = error (show a)
forceEither (Right b) = b

-- | Switches all names to case sensitive (unlike by default in ConfigFile).
toSensitive :: CF.ConfigParser -> CF.ConfigParser
toSensitive cp = cp {CF.optionxform = id}

toCP :: CF.ConfigParser -> CP
toCP cf = CP $ toSensitive cf

-- | The argument 'configDefault' is expected to be the default configuration
-- taken from the default configuration file included via CPP
-- in ConfigDefault.hs. It is overwritten completely by
-- the configuration read from the user configuration file, if any.
mkConfig :: String -> IO CP
mkConfig configDefault = do
  -- Evaluate, to catch config errors ASAP.
  let !defCF = forceEither $ CF.readstring CF.emptyCP configDefault
  cfile <- configFile
  b <- doesFileExist cfile
  if not b
    then return $ toCP defCF
    else do
     c <- CF.readfile CF.emptyCP cfile
     return $ toCP $ forceEither c

appDataDir :: IO FilePath
appDataDir = do
  progName <- getProgName
  let name = L.takeWhile Char.isAlphaNum progName
  getAppUserDataDirectory name

-- | Path to the user configuration file.
configFile :: IO FilePath
configFile = do
  appData <- appDataDir
  return $ combine appData "config"

-- | A simplified access to an option in a given section,
-- with simple error reporting (no error is caught and hidden).
-- If there is no config file or no such option, gives Nothing.
getOption :: CF.Get_C a => CP -> CF.SectionSpec -> CF.OptionSpec -> Maybe a
getOption (CP conf) s o =
  if CF.has_option conf s o
  then Just $ forceEither $ CF.get conf s o
  else Nothing

-- | Simplified access to an option in a given section.
get :: CF.Get_C a => CP -> CF.SectionSpec -> CF.OptionSpec -> a
get (CP conf) s o =
  if CF.has_option conf s o
  then forceEither $ CF.get conf s o
  else error $ "Unknown config option: " ++ s ++ "." ++ o

-- | Simplified setting of an option in a given section. Overwriting forbidden.
set :: CP -> CF.SectionSpec -> CF.OptionSpec -> String -> CP
set (CP conf) s o v =
  if CF.has_option conf s o
  then error $ "Overwritten config option: " ++ s ++ "." ++ o
  else CP $ forceEither $ CF.set conf s o v

-- | An association list corresponding to a section.
getItems :: CP -> CF.SectionSpec -> [(String, String)]
getItems (CP conf) s =
  if CF.has_section conf s
  then forceEither $ CF.items conf s
  else error $ "Unknown config section: " ++ s

-- | Looks up a file path in the config file and makes it absolute.
-- If the game's configuration directory exists,
-- the path is appended to it; otherwise, it's appended
-- to the current directory.
getFile :: CP -> CF.SectionSpec -> CF.OptionSpec -> IO FilePath
getFile conf s o = do
  current <- getCurrentDirectory
  appData <- appDataDir
  let path    = get conf s o
      appPath = combine appData path
      curPath = combine current path
  b <- doesDirectoryExist appData
  return $ if b then appPath else curPath

dump :: FilePath -> CP -> IO ()
dump fn (CP conf) = do
  current <- getCurrentDirectory
  let path  = combine current fn
      sdump = CF.to_string conf
  writeFile path sdump
