-- | Inventory management and party cycling.
-- TODO: document
module Game.LambdaHack.Client.UI.InventoryClient
  ( failMsg, msgNoChangeDunLeader, msgNoChangeLvlLeader
  , getGroupItem, getAnyItem, getStoreItem
  , memberCycle, memberBack, pickLeader
  ) where

import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.Char as Char
import qualified Data.EnumMap.Strict as EM
import Data.Function
import qualified Data.IntMap.Strict as IM
import Data.List
import Data.Maybe
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Client.CommonClient
import Game.LambdaHack.Client.ItemSlot
import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.MonadClientUI
import Game.LambdaHack.Client.UI.MsgClient
import Game.LambdaHack.Client.UI.WidgetClient
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.State

failMsg :: MonadClientUI m => Msg -> m Slideshow
failMsg msg = do
  stopPlayBack
  assert (not $ T.null msg) $ promptToSlideshow msg

-- | Let a human player choose any item from a given group.
-- Note that this does not guarantee the chosen item belongs to the group,
-- as the player can override the choice.
getGroupItem :: MonadClientUI m
             => (Item -> Bool)  -- ^ which items to consider suitable
             -> MU.Part   -- ^ name of the item group
             -> MU.Part   -- ^ the verb describing the action
             -> [CStore]  -- ^ initial legal containers
             -> [CStore]  -- ^ legal containers after Calm taken into account
             -> m (SlideOrCmd ((ItemId, ItemFull), Container))
getGroupItem p itemsName verb cLegalRaw cLegalAfterCalm = do
  leader <- getLeaderUI
  getCStoreBag <- getsState $ \s cstore -> getCBag (CActor leader cstore) s
  let cNotEmpty = not . EM.null . getCStoreBag
      cLegal = filter cNotEmpty cLegalAfterCalm  -- don't display empty stores
      tsuitable = const $ makePhrase [MU.Capitalize (MU.Ws itemsName)]
  getItem p (\b _ -> tsuitable b) tsuitable verb
          (map (CActor leader) cLegalRaw)
          (map (CActor leader) cLegal)
          True INone

-- | Let the human player choose any item from a list of items
-- and let him specify the number of items.
getAnyItem :: MonadClientUI m
           => MU.Part   -- ^ the verb describing the action
           -> [CStore]  -- ^ initial legal containers
           -> [CStore]  -- ^ legal containers after Calm taken into account
           -> Bool      -- ^ whether to ask, when the only item
                        --   in the starting container is suitable
           -> Bool      -- ^ whether to ask for the number of items
           -> m (SlideOrCmd ((ItemId, ItemFull), Container))
getAnyItem verb cLegalRaw cLegalAfterCalm askWhenLone askNumber = do
  leader <- getLeaderUI
  soc <- getItem (const True) (\_ _ -> "Items") (const "Items") verb
                 (map (CActor leader) cLegalRaw)
                 (map (CActor leader) cLegalAfterCalm)
                 askWhenLone INone
  case soc of
    Left _ -> return soc
    Right ((iid, itemFull), c) -> do
      socK <- pickNumber askNumber $ itemK itemFull
      case socK of
        Left slides -> return $ Left slides
        Right k ->
          return $ Right ((iid, itemFull{itemK=k}), c)

-- | Display all items from a store and let the human player choose any
-- or switch to any other store.
getStoreItem :: MonadClientUI m
             => (Actor -> [ItemFull] -> Text)
                                 -- ^ how to describe suitable items in CSha
             -> (Actor -> Text)  -- ^ how to describe suitable items elsewhere
             -> MU.Part          -- ^ the verb describing the action
             -> Container        -- ^ initial container
             -> m (SlideOrCmd ((ItemId, ItemFull), Container))
getStoreItem shaBlurb stdBlurb verb cInitial = do
  leader <- getLeaderUI
  let allStores = map (CActor leader) [CEqp, CInv, CSha, CGround]
      cLegalRaw = cInitial : delete cInitial allStores
  getItem (const True) shaBlurb stdBlurb verb cLegalRaw cLegalRaw
          True ISuitable

data ItemDialogState = INone | ISuitable | IAll
  deriving (Show, Eq)

-- | Let the human player choose a single, preferably suitable,
-- item from a list of items.
getItem :: MonadClientUI m
        => (Item -> Bool)   -- ^ which items to consider suitable
        -> (Actor -> [ItemFull] -> Text)
                            -- ^ how to describe suitable items in CSha
        -> (Actor -> Text)  -- ^ how to describe suitable items elsewhere
        -> MU.Part          -- ^ the verb describing the action
        -> [Container]      -- ^ initial legal containers
        -> [Container]      -- ^ legal containers with Calm taken into account
        -> Bool             -- ^ whether to ask, when the only item
                            --   in the starting container is suitable
        -> ItemDialogState  -- ^ the dialog state to start in
        -> m (SlideOrCmd ((ItemId, ItemFull), Container))
getItem p tshaSuit tsuitable verb cLegalRaw cLegal askWhenLone initalState = do
  leader <- getLeaderUI
  accessCBag <- getsState $ flip getCBag
  let storeAssocs = EM.assocs . accessCBag
      allAssocs = concatMap storeAssocs cLegal
      rawAssocs = concatMap storeAssocs cLegalRaw
  case (cLegal, allAssocs) of
    ([cStart], [(iid, k)]) | not askWhenLone -> do
      itemToF <- itemToFullClient
      return $ Right ((iid, itemToF iid k), cStart)
    (_ : _, _ : _) -> do
      let groundCs = filter ((== CGround) . storeFromC) cLegal
      mapM_ (updateItemSlot (Just leader)) $
        concatMap (EM.keys . accessCBag) groundCs
      transition p tshaSuit tsuitable verb cLegal initalState
    _ -> if null rawAssocs then do
           let tLegal = map (MU.Text . ppContainer) cLegalRaw
               ppLegal = makePhrase [MU.WWxW "nor" tLegal]
           failWith $ "no items" <+> ppLegal
         else failSer ItemNotCalm

-- TODO: m is no longer needed and perhaps this can be simplified even more
data DefItemKey m = DefItemKey
  { defLabel  :: Text
  , defCond   :: Bool
  , defAction :: K.Key -> m (SlideOrCmd ((ItemId, ItemFull), Container))
  }

transition :: forall m. MonadClientUI m
           => (Item -> Bool)   -- ^ which items to consider suitable
           -> (Actor -> [ItemFull] -> Text)
                               -- ^ how to describe suitable items in CSha
           -> (Actor -> Text)  -- ^ how to describe suitable items elsewhere
           -> MU.Part          -- ^ the verb describing the action
           -> [Container]
           -> ItemDialogState
           -> m (SlideOrCmd ((ItemId, ItemFull), Container))
transition _ _ _ verb [] iDS = assert `failure` (verb, iDS)
transition psuit tshaSuit tsuitable verb
           cLegal@(cCur:cRest) itemDialogState = do
  (letterSlots, numberSlots) <- getsClient sslots
  leader <- getLeaderUI
  body <- getsState $ getActorBody leader
  activeItems <- activeItemsClient leader
  fact <- getsState $ (EM.! bfid body) . sfactionD
  hs <- partyAfterLeader leader
  bag <- getsState $ getCBag cCur
  itemToF <- itemToFullClient
  let getResult :: ItemId -> ((ItemId, ItemFull), Container)
      getResult iid = ((iid, itemToF iid (bag EM.! iid)), cCur)
      filterP s iid _ = psuit (getItemBody iid s)
  bagSuit <- getsState $ \s -> EM.filterWithKey (filterP s) bag
  let bagLetterSlots = EM.filter (`EM.member` bag) letterSlots
      bagNumberSlots = IM.filter (`EM.member` bag) numberSlots
      suitableLetterSlots = EM.filter (`EM.member` bagSuit) letterSlots
      (autoDun, autoLvl) = autoDungeonLevel fact
      keyDefs :: [(K.Key, DefItemKey m)]
      keyDefs = filter (defCond . snd)
        [ (K.Char '?', DefItemKey
           { defLabel = "?"
           , defCond = True
           , defAction = \_ -> case itemDialogState of
               INone ->
                 if EM.null bagSuit
                 then transition psuit tshaSuit tsuitable verb cLegal IAll
                 else transition psuit tshaSuit tsuitable verb cLegal ISuitable
               ISuitable | bag /= bagSuit ->
                 transition psuit tshaSuit tsuitable verb cLegal IAll
               _ -> transition psuit tshaSuit tsuitable verb cLegal INone
           })
        , (K.Char '/', DefItemKey
           { defLabel = "/"
           , defCond = length cLegal > 1
           , defAction = \_ -> transition psuit tshaSuit tsuitable verb
                                          (cRest ++ [cCur]) itemDialogState
           })
        , (K.Return,
           let enterSlots = if itemDialogState == IAll
                            then bagLetterSlots
                            else suitableLetterSlots
           in DefItemKey
           { defLabel = case EM.maxViewWithKey enterSlots of
               Nothing -> assert `failure` "no suitable items"
                                 `twith` enterSlots
               Just ((l, _), _) -> "RET(" <> T.singleton (slotChar l) <> ")"
           , defCond = not $ EM.null enterSlots
           , defAction = \_ -> case EM.maxView enterSlots of
               Nothing -> assert `failure` "no suitable items"
                                 `twith` enterSlots
               Just (iid, _) -> return $ Right $ getResult iid
           })
        , (K.Char '0', DefItemKey  -- TODO: accept any number and pick the item
           { defLabel = "0"
           , defCond = not $ IM.null bagNumberSlots
           , defAction = \_ -> case IM.minView bagNumberSlots of
               Nothing -> assert `failure` "no numbered items"
                                 `twith` bagNumberSlots
               Just (iid, _) -> return $ Right $ getResult iid
           })
        , (K.Tab, DefItemKey
           { defLabel = "TAB"
           , defCond = not (autoLvl
                            || null (filter (\(_, b) ->
                                               blid b == blid body) hs))
           , defAction = \_ -> do
               err <- memberCycle False
               assert (err == mempty `blame` err) skip
               newLeader <- getLeaderUI
               let newC c = case c of
                     CActor _ cstore -> CActor newLeader cstore
                     _ -> c
                   newLegal = map newC cLegal
               transition psuit tshaSuit tsuitable verb newLegal itemDialogState
           })
        , (K.BackTab, DefItemKey
           { defLabel = "SHIFT-TAB"
           , defCond = not (autoDun || null hs)
           , defAction = \_ -> do
               err <- memberBack False
               assert (err == mempty `blame` err) skip
               newLeader <- getLeaderUI
               let newC c = case c of
                     CActor _ cstore -> CActor newLeader cstore
                     _ -> c
                   newLegal = map newC cLegal
               transition psuit tshaSuit tsuitable verb newLegal itemDialogState
           })
        ]
      lettersDef :: DefItemKey m
      lettersDef = DefItemKey
        { defLabel = slotRange $ EM.keys labelLetterSlots
        , defCond = True
        , defAction = \key -> case key of
            K.Char l -> case EM.lookup (SlotChar l) bagLetterSlots of
              Nothing -> assert `failure` "unexpected slot"
                                `twith` (l, bagLetterSlots)
              Just iid -> return $ Right $ getResult iid
            _ -> assert `failure` "unexpected key:" `twith` K.showKey key
        }
      ppCur = ppContainer cCur
      tsuit = if storeFromC cCur == CSha
              then tshaSuit body activeItems
              else tsuitable body
      (labelLetterSlots, bagFiltered, prompt) =
        case itemDialogState of
          INone     -> (suitableLetterSlots,
                        EM.empty,
                        makePhrase ["What to", verb] <+> ppCur <> "?")
          ISuitable -> (suitableLetterSlots,
                        bagSuit,
                        tsuit <+> ppCur <> ":")
          IAll      -> (bagLetterSlots,
                        bag,
                        "Items" <+> ppCur <> ":")
  io <- itemOverlay (storeFromC cCur) bagFiltered
  runDefItemKey keyDefs lettersDef io labelLetterSlots prompt

runDefItemKey :: MonadClientUI m
              => [(K.Key, DefItemKey m)]
              -> DefItemKey m
              -> Overlay
              -> EM.EnumMap SlotChar ItemId
              -> Text
              -> m (SlideOrCmd ((ItemId, ItemFull), Container))
runDefItemKey keyDefs lettersDef io labelLetterSlots prompt = do
  let itemKeys =
        let slotKeys = map (K.Char . slotChar) (EM.keys labelLetterSlots)
            defKeys = map fst keyDefs
        in zipWith K.KM (repeat K.NoModifier) $ slotKeys ++ defKeys
      choice = let letterRange = defLabel lettersDef
                   letterLabel | T.null letterRange = []
                               | otherwise = [letterRange]
                   keyLabels = letterLabel ++ map (defLabel . snd) keyDefs
               in "[" <> T.intercalate ", " keyLabels
  akm <- displayChoiceUI (prompt <+> choice) io itemKeys
  case akm of
    Left slides -> failSlides slides
    Right K.KM{..} -> do
      assert (modifier == K.NoModifier) skip
      case lookup key keyDefs of
        Just keyDef -> defAction keyDef key
        Nothing -> defAction lettersDef key

pickNumber :: MonadClientUI m => Bool -> Int -> m (SlideOrCmd Int)
pickNumber askNumber kAll = do
  let kDefault = kAll
  if askNumber && kAll > 1 then do
    let tDefault = tshow kDefault
        kbound = min 9 kAll
        kprompt = "Choose number [1-" <> tshow kbound
                  <> ", RET(" <> tDefault <> ")"
        kkeys = zipWith K.KM (repeat K.NoModifier)
                $ map (K.Char . Char.intToDigit) [1..kbound]
                  ++ [K.Return]
    kkm <- displayChoiceUI kprompt emptyOverlay kkeys
    case kkm of
      Left slides -> failSlides slides
      Right K.KM{key} ->
        case key of
          K.Char l -> return $ Right $ Char.digitToInt l
          K.Return -> return $ Right kDefault
          _ -> assert `failure` "unexpected key:" `twith` kkm
  else return $ Right kAll

-- | Switches current member to the next on the level, if any, wrapping.
memberCycle :: MonadClientUI m => Bool -> m Slideshow
memberCycle verbose = do
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  leader <- getLeaderUI
  body <- getsState $ getActorBody leader
  hs <- partyAfterLeader leader
  let autoLvl = snd $ autoDungeonLevel fact
  case filter (\(_, b) -> blid b == blid body) hs of
    _ | autoLvl -> failMsg $ showReqFailure NoChangeLvlLeader
    [] -> failMsg "Cannot pick any other member on this level."
    (np, b) : _ -> do
      success <- pickLeader verbose np
      assert (success `blame` "same leader" `twith` (leader, np, b)) skip
      return mempty

-- | Switches current member to the previous in the whole dungeon, wrapping.
memberBack :: MonadClientUI m => Bool -> m Slideshow
memberBack verbose = do
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  leader <- getLeaderUI
  hs <- partyAfterLeader leader
  let autoDun = fst $ autoDungeonLevel fact
  case reverse hs of
    _ | autoDun -> failMsg $ showReqFailure NoChangeDunLeader
    [] -> failMsg "No other member in the party."
    (np, b) : _ -> do
      success <- pickLeader verbose np
      assert (success `blame` "same leader" `twith` (leader, np, b)) skip
      return mempty

msgNoChangeDunLeader :: Msg
msgNoChangeDunLeader = "level change is automatic for your team"

msgNoChangeLvlLeader :: Msg
msgNoChangeLvlLeader = "leader change is automatic for your team"

partyAfterLeader :: MonadStateRead m => ActorId -> m [(ActorId, Actor)]
partyAfterLeader leader = do
  faction <- getsState $ bfid . getActorBody leader
  allA <- getsState $ EM.assocs . sactorD
  s <- getState
  let hs9 = mapMaybe (tryFindHeroK s faction) [0..9]
      factionA = filter (\(_, body) ->
        not (bproj body) && bfid body == faction) allA
      hs = hs9 ++ deleteFirstsBy ((==) `on` fst) factionA hs9
      i = fromMaybe (-1) $ findIndex ((== leader) . fst) hs
      (lt, gt) = (take i hs, drop (i + 1) hs)
  return $! gt ++ lt

-- | Select a faction leader. False, if nothing to do.
pickLeader :: MonadClientUI m => Bool -> ActorId -> m Bool
pickLeader verbose aid = do
  leader <- getLeaderUI
  stgtMode <- getsClient stgtMode
  if leader == aid
    then return False -- already picked
    else do
      pbody <- getsState $ getActorBody aid
      assert (not (bproj pbody) `blame` "projectile chosen as the leader"
                                `twith` (aid, pbody)) skip
      -- Even if it's already the leader, give his proper name, not 'you'.
      let subject = partActor pbody
      when verbose $ msgAdd $ makeSentence [subject, "picked as a leader"]
      -- Update client state.
      s <- getState
      modifyClient $ updateLeader aid s
      -- Move the cursor, if active, to the new level.
      case stgtMode of
        Nothing -> return ()
        Just _ ->
          modifyClient $ \cli -> cli {stgtMode = Just $ TgtMode $ blid pbody}
      -- Inform about items, etc.
      lookMsg <- lookAt False "" True (bpos pbody) aid ""
      when verbose $ msgAdd lookMsg
      return True
