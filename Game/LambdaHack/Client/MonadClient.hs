-- | Basic client monad and related operations.
module Game.LambdaHack.Client.MonadClient
  ( -- * Basic client monad
    MonadClient( getClient, getsClient, modifyClient, putClient
               , saveChanClient  -- exposed only to be implemented, not used
               , liftIO  -- exposed only to be implemented, not used
               )
    -- * Assorted primitives
  , debugPrint, saveClient, saveName, restoreGame, removeServerSave, rndToAction
  ) where

import Control.Monad
import qualified Control.Monad.State as St
import Data.Maybe
import Data.Text (Text)
import System.Directory
import System.FilePath

import Game.LambdaHack.Client.State
import Game.LambdaHack.Common.ClientOptions
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.File
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Random
import qualified Game.LambdaHack.Common.Save as Save
import Game.LambdaHack.Common.State
import Game.LambdaHack.Content.RuleKind

class MonadStateRead m => MonadClient m where
  getClient      :: m StateClient
  getsClient     :: (StateClient -> a) -> m a
  modifyClient   :: (StateClient -> StateClient) -> m ()
  putClient      :: StateClient -> m ()
  -- We do not provide a MonadIO instance, so that outside of Action/
  -- nobody can subvert the action monads by invoking arbitrary IO.
  liftIO         :: IO a -> m a
  saveChanClient :: m (Save.ChanSave (State, StateClient))

debugPrint :: MonadClient m => Text -> m ()
debugPrint t = do
  sdbgMsgCli <- getsClient $ sdbgMsgCli . sdebugCli
  when sdbgMsgCli $ liftIO $ Save.delayPrint t

saveClient :: MonadClient m => m ()
saveClient = do
  s <- getState
  cli <- getClient
  toSave <- saveChanClient
  liftIO $ Save.saveToChan toSave (s, cli)

saveName :: FactionId -> Bool -> String
saveName side isAI =
  let n = fromEnum side  -- we depend on the numbering hack to number saves
  in (if n > 0
      then "human_" ++ show n
      else "computer_" ++ show (-n))
     ++ if isAI then ".ai.sav" else ".ui.sav"

restoreGame :: MonadClient m => m (Maybe (State, StateClient))
restoreGame = do
  bench <- getsClient $ sbenchmark . sdebugCli
  if bench then return Nothing
  else do
    Kind.COps{corule} <- getsState scops
    let stdRuleset = Kind.stdRuleset corule
        pathsDataFile = rpathsDataFile stdRuleset
        cfgUIName = rcfgUIName stdRuleset
    side <- getsClient sside
    isAI <- getsClient sisAI
    prefix <- getsClient $ ssavePrefixCli . sdebugCli
    let copies = [( "GameDefinition" </> cfgUIName <.> "default"
                  , cfgUIName <.> "ini" )]
        name = fromMaybe "save" prefix <.> saveName side isAI
    liftIO $ Save.restoreGame name copies pathsDataFile

-- | Assuming the client runs on the same machine and for the same
-- user as the server, move the server savegame out of the way.
removeServerSave :: MonadClient m => m ()
removeServerSave = do
  -- Hack: assume the same prefix for client as for the server.
  prefix <- getsClient $ ssavePrefixCli . sdebugCli
  dataDir <- liftIO appDataDir
  let serverSaveFile = dataDir
                       </> "saves"
                       </> fromMaybe "save" prefix
                       <.> serverSaveName
  bSer <- liftIO $ doesFileExist serverSaveFile
  when bSer $ liftIO $ renameFile serverSaveFile (serverSaveFile <.> "bkp")

-- | Invoke pseudo-random computation with the generator kept in the state.
rndToAction :: MonadClient m => Rnd a -> m a
rndToAction r = do
  g <- getsClient srandom
  let (a, ng) = St.runState r g
  modifyClient $ \cli -> cli {srandom = ng}
  return a
