-- | Display game data on the screen using one of the available frontends
-- (determined at compile time with cabal flags).
module Game.LambdaHack.Client.UI.DrawClient
  ( ColorMode(..)
  , draw
  ) where

import Control.Exception.Assert.Sugar
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import qualified Data.IntMap.Strict as IM
import Data.List
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T

import Game.LambdaHack.Client.Bfs
import Game.LambdaHack.Client.CommonClient
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.Animation
import Game.LambdaHack.Common.Actor as Actor
import Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Color as Color
import qualified Game.LambdaHack.Common.Dice as Dice
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.ItemDescription
import Game.LambdaHack.Common.ItemStrongest
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Point
import qualified Game.LambdaHack.Common.PointArray as PointArray
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.ItemKind
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Content.TileKind

-- | Color mode for the display.
data ColorMode =
    ColorFull  -- ^ normal, with full colours
  | ColorBW    -- ^ black+white only

-- TODO: split up and generally rewrite.
-- | Draw the whole screen: level map and status area.
-- Pass at most a single page if overlay of text unchanged
-- to the frontends to display separately or overlay over map,
-- depending on the frontend.
draw :: MonadClient m
     => Bool -> ColorMode -> LevelId
     -> Maybe Point -> Maybe Point
     -> Maybe (PointArray.Array BfsDistance, Maybe [Point])
     -> (Text, Maybe Text) -> (Text, Maybe Text) -> Overlay
     -> m SingleFrame
draw sfBlank dm drawnLevelId cursorPos tgtPos bfsmpathRaw
     (cursorDesc, mcursorHP) (targetDesc, mtargetHP) sfTop = do
  cops <- getsState scops
  mleader <- getsClient _sleader
  s <- getState
  cli@StateClient{ stgtMode, seps, sexplored
                 , smarkVision, smarkSmell, smarkSuspect, swaitTimes }
    <- getClient
  per <- getPerFid drawnLevelId
  let Kind.COps{cotile=cotile@Kind.Ops{okind=tokind, ouniqGroup}} = cops
      (lvl@Level{lxsize, lysize, lsmell, ltime}) = sdungeon s EM.! drawnLevelId
      (bl, mblid, mbpos) = case (cursorPos, mleader) of
        (Just cursor, Just leader) ->
          let Actor{bpos, blid} = getActorBody leader s
          in if blid /= drawnLevelId
             then ( [cursor], Just blid, Just bpos )
             else ( fromMaybe [] $ bla lxsize lysize seps bpos cursor
                  , Just blid
                  , Just bpos )
        _ -> ([], Nothing, Nothing)
      mpath = maybe Nothing (\(_, mp) -> if null bl
                                            || mblid /= Just drawnLevelId
                                         then Nothing
                                         else mp) bfsmpathRaw
      actorsHere = actorAssocs (const True) drawnLevelId s
      cursorHere = find (\(_, m) -> cursorPos == Just (Actor.bpos m))
                   actorsHere
      shiftedBTrajectory = case cursorHere of
        Just (_, Actor{btrajectory = Just p, bpos = prPos}) ->
          trajectoryToPath prPos (fst p)
        _ -> []
      unknownId = ouniqGroup "unknown space"
      dis pos0 =
        let tile = lvl `at` pos0
            tk = tokind tile
            floorBag = lvl `atI` pos0
            (letterSlots, numberSlots) = sslots cli
            bagLetterSlots = EM.filter (`EM.member` floorBag) letterSlots
            bagNumberSlots = IM.filter (`EM.member` floorBag) numberSlots
            floorIids = reverse (EM.elems bagLetterSlots)
                        ++ IM.elems bagNumberSlots
                        ++ EM.keys floorBag
            sml = EM.findWithDefault timeZero pos0 lsmell
            smlt = sml `timeDeltaToFrom` ltime
            viewActor aid Actor{bsymbol, bcolor, bhp, bproj}
              | Just aid == mleader = (symbol, inverseVideo)
              | otherwise = (symbol, Color.defAttr {Color.fg = bcolor})
             where
              symbol | bhp <= 0 && not bproj = '%'
                     | otherwise = bsymbol
            rainbow p = Color.defAttr {Color.fg =
                                         toEnum $ fromEnum p `rem` 14 + 1}
            -- smarkSuspect is an optional overlay, so let's overlay it
            -- over both visible and invisible tiles.
            vcolor
              | smarkSuspect && Tile.isSuspect cotile tile = Color.BrCyan
              | vis = tcolor tk
              | otherwise = tcolor2 tk
            fgOnPathOrLine = case (vis, Tile.isWalkable cotile tile) of
              _ | tile == unknownId -> Color.BrBlack
              _ | Tile.isSuspect cotile tile -> Color.BrCyan
              (True, True)   -> Color.BrGreen
              (True, False)  -> Color.BrRed
              (False, True)  -> Color.Green
              (False, False) -> Color.Red
            atttrOnPathOrLine = if Just pos0 == cursorPos
                                then inverseVideo {Color.fg = fgOnPathOrLine}
                                else Color.defAttr {Color.fg = fgOnPathOrLine}
            (char, attr0) =
              case find (\(_, m) -> pos0 == Actor.bpos m) actorsHere of
                _ | isJust stgtMode
                    && (elem pos0 bl || elem pos0 shiftedBTrajectory) ->
                  ('*', atttrOnPathOrLine)  -- line takes precedence over path
                _ | isJust stgtMode
                    && (maybe False (elem pos0) mpath) ->
                  (';', Color.defAttr {Color.fg = fgOnPathOrLine})
                Just (aid, m) -> viewActor aid m
                _ | smarkSmell && sml > ltime ->
                  (timeDeltaToDigit smellTimeout smlt, rainbow pos0)
                  | otherwise ->
                  case floorIids of
                    [] -> (tsymbol tk, Color.defAttr {Color.fg = vcolor})
                    iid : _ -> viewItem $ getItemBody iid s
            vis = ES.member pos0 $ totalVisible per
            a = case dm of
                  ColorBW -> Color.defAttr
                  ColorFull -> if smarkVision && vis
                               then attr0 {Color.bg = Color.Blue}
                               else attr0
        in Color.AttrChar a char
      widthX = 80
      widthTgt = 39
      widthStats = widthX - widthTgt
      addAttr t = map (Color.AttrChar Color.defAttr) (T.unpack t)
      arenaStatus = drawArenaStatus (ES.member drawnLevelId sexplored) lvl
                                    widthStats
      displayPathText mp mt =
        let (plen, llen) = case (mp, bfsmpathRaw, mbpos) of
              (Just target, Just (bfs, _), Just bpos)
                | mblid == Just drawnLevelId ->
                  (fromMaybe 0 (accessBfs bfs target), chessDist bpos target)
              _ -> (0, 0)
            pText | plen == 0 = ""
                  | otherwise = "p" <> tshow plen
            lText | llen == 0 = ""
                  | otherwise = "l" <> tshow llen
            text = fromMaybe (pText <+> lText) mt
        in if T.null text then "" else " " <> text
      -- The indicators must fit, they are the actual information.
      pathCsr = displayPathText cursorPos mcursorHP
      trimTgtDesc n t = assert (not (T.null t) && n > 2) $
        if T.length t <= n then t
        else let ellipsis = "..."
                 fitsPlusOne = T.take (n - T.length ellipsis + 1) t
                 fits = if T.last fitsPlusOne == ' '
                        then T.init fitsPlusOne
                        else let lw = T.words fitsPlusOne
                             in T.unwords $ init lw
             in fits <> ellipsis
      cursorText =
        let n = widthTgt - T.length pathCsr - 8
        in (if isJust stgtMode then "cursor>" else "Cursor:")
           <+> trimTgtDesc n cursorDesc
      cursorGap = T.replicate (widthTgt - T.length pathCsr
                                        - T.length cursorText) " "
      cursorStatus = addAttr $ cursorText <> cursorGap <> pathCsr
      minLeaderStatusWidth = 19  -- covers 3-digit HP
  selectedStatus <- drawSelected drawnLevelId
                                 (widthStats - minLeaderStatusWidth)
  leaderStatus <- drawLeaderStatus swaitTimes
                                   (widthStats - length selectedStatus)
  damageStatus <- drawLeaderDamage (widthStats - length leaderStatus
                                               - length selectedStatus)
  nameStatus <- drawPlayerName (widthStats - length leaderStatus
                                           - length selectedStatus
                                           - length damageStatus)
  let statusGap = addAttr $ T.replicate (widthStats - length leaderStatus
                                                    - length selectedStatus
                                                    - length damageStatus
                                                    - length nameStatus) " "
      -- The indicators must fit, they are the actual information.
      pathTgt = displayPathText tgtPos mtargetHP
      targetText =
        let n = widthTgt - T.length pathTgt - 8
        in "Target:" <+> trimTgtDesc n targetDesc
      targetGap = T.replicate (widthTgt - T.length pathTgt
                                        - T.length targetText) " "
      targetStatus = addAttr $ targetText <> targetGap <> pathTgt
      sfBottom =
        [ encodeLine $ arenaStatus ++ cursorStatus
        , encodeLine $ selectedStatus ++ nameStatus ++ statusGap
                       ++ damageStatus ++ leaderStatus
                       ++ targetStatus ]
      fLine y = encodeLine $
        let f l x = let ac = dis $ Point x y in ac : l
        in foldl' f [] [lxsize-1,lxsize-2..0]
      sfLevel =  -- fully evaluated
        let f l y = let !line = fLine y in line : l
        in foldl' f [] [lysize-1,lysize-2..0]
  return $! SingleFrame{..}

inverseVideo :: Color.Attr
inverseVideo = Color.Attr { Color.fg = Color.bg Color.defAttr
                          , Color.bg = Color.fg Color.defAttr }

-- Comfortably accomodates 3-digit level numbers and 25-character
-- level descriptions (currently enforced max).
drawArenaStatus :: Bool -> Level -> Int -> [Color.AttrChar]
drawArenaStatus explored Level{ldepth=AbsDepth ld, ldesc, lseen, lclear} width =
  let addAttr t = map (Color.AttrChar Color.defAttr) (T.unpack t)
      seenN = 100 * lseen `div` max 1 lclear
      seenTxt | explored || seenN >= 100 = "all"
              | otherwise = T.justifyLeft 3 ' ' (tshow seenN <> "%")
      lvlN = T.justifyLeft 2 ' ' (tshow ld)
      seenStatus = "[" <> seenTxt <+> "seen] "
  in addAttr $ T.justifyLeft width ' '
             $ T.take 29 (lvlN <+> T.justifyLeft 26 ' ' ldesc) <+> seenStatus

drawLeaderStatus :: MonadClient m => Int -> Int -> m [Color.AttrChar]
drawLeaderStatus waitT width = do
  mleader <- getsClient _sleader
  s <- getState
  let addAttr t = map (Color.AttrChar Color.defAttr) (T.unpack t)
      addColor c t = map (Color.AttrChar $ Color.Attr c Color.defBG)
                         (T.unpack t)
      maxLeaderStatusWidth = 23  -- covers 3-digit HP and 2-digit Calm
      (calmHeaderText, hpHeaderText) = if width < maxLeaderStatusWidth
                                       then ("C", "H")
                                       else ("Calm", "HP")
  case mleader of
    Just leader -> do
      activeItems <- activeItemsClient leader
      let (darkL, bracedL, hpDelta, calmDelta,
           ahpS, bhpS, acalmS, bcalmS) =
            let b@Actor{bhp, bcalm} = getActorBody leader s
                amaxHP = sumSlotNoFilter Effect.EqpSlotAddMaxHP activeItems
                amaxCalm = sumSlotNoFilter Effect.EqpSlotAddMaxCalm activeItems
            in ( not (actorInAmbient b s)
               , braced b, bhpDelta b, bcalmDelta b
               , tshow $ max 0 amaxHP, tshow (bhp `divUp` oneM)
               , tshow $ max 0 amaxCalm, tshow (bcalm `divUp` oneM))
          -- This is a valuable feedback for the otherwise hard to observe
          -- 'wait' command.
          slashes = ["/", "|", "\\", "|"]
          slashPick = slashes !! (max 0 (waitT - 1) `mod` length slashes)
          checkDelta ResDelta{..} =
            if resCurrentTurn < 0 || resPreviousTurn < 0
            then addColor Color.BrRed  -- alarming news have priority
            else if resCurrentTurn > 0 || resPreviousTurn > 0
                 then addColor Color.BrGreen
                 else addAttr  -- only if nothing at all noteworthy
          calmAddAttr = checkDelta calmDelta
          darkPick | darkL   = "."
                   | otherwise = ":"
          calmHeader = calmAddAttr $ calmHeaderText <> darkPick
          calmText = bcalmS <>  (if darkL then slashPick else "/") <> acalmS
          bracePick | bracedL   = "}"
                    | otherwise = ":"
          hpAddAttr = checkDelta hpDelta
          hpHeader = hpAddAttr $ hpHeaderText <> bracePick
          hpText = bhpS <> (if bracedL then slashPick else "/") <> ahpS
      return $! calmHeader <> addAttr (T.justifyRight 6 ' ' calmText <> " ")
                <> hpHeader <> addAttr (T.justifyRight 6 ' ' hpText <> " ")
    Nothing -> return $! addAttr $ calmHeaderText <> ": --/-- "
                                   <> hpHeaderText <> ": --/-- "

drawLeaderDamage :: MonadClient m => Int -> m [Color.AttrChar]
drawLeaderDamage width = do
  mleader <- getsClient _sleader
  let addColor t = map (Color.AttrChar $ Color.Attr Color.BrCyan Color.defBG)
                   (T.unpack t)
  stats <- case mleader of
    Just leader -> do
      allAssocs <- fullAssocsClient leader [CEqp, COrgan]
      let activeItems = map snd allAssocs
          damage = case strongestSlotNoFilter Effect.EqpSlotWeapon allAssocs of
            (_, (_, itemFull)) : _->
              let getD :: Effect.Effect a -> Maybe Dice.Dice
                       -> Maybe Dice.Dice
                  getD (Effect.Hurt dice) _ = Just dice
                  getD _ acc = acc
                  mdice = case itemDisco itemFull of
                    Just ItemDisco{itemAE=Just ItemAspectEffect{jeffects}} ->
                      foldr getD Nothing jeffects
                    Just ItemDisco{itemKind} ->
                      foldr getD Nothing (ieffects itemKind)
                    Nothing -> Nothing
                  tdice = case mdice of
                    Nothing -> "0"
                    Just dice -> tshow dice
                  bonus = sumSlotNoFilter Effect.EqpSlotAddHurtMelee activeItems
                  unknownBonus = unknownMelee activeItems
                  tbonus = if bonus == 0
                           then if unknownBonus then "+?" else ""
                           else (if bonus > 0 then "+" else "")
                                <> tshow bonus
                                <> if unknownBonus then "%?" else "%"
             in tdice <> tbonus
            [] -> "0"
      return $! damage
    Nothing -> return ""
  return $! if T.null stats || T.length stats >= width then []
            else addColor $ stats <> " "

-- TODO: colour some texts using the faction's colour
drawSelected :: MonadClient m => LevelId -> Int -> m [Color.AttrChar]
drawSelected drawnLevelId width = do
  mleader <- getsClient _sleader
  selected <- getsClient sselected
  side <- getsClient sside
  s <- getState
  let viewOurs (aid, Actor{bsymbol, bcolor, bhp})
        | otherwise =
          let cattr = Color.defAttr {Color.fg = bcolor}
              sattr
               | Just aid == mleader = inverseVideo
               | ES.member aid selected =
                   -- TODO: in the future use a red rectangle instead
                   -- of background and mark them on the map, too;
                   -- also, perhaps blink all selected on the map,
                   -- when selection changes
                   if bcolor /= Color.Blue
                   then cattr {Color.bg = Color.Blue}
                   else cattr {Color.bg = Color.Magenta}
               | otherwise = cattr
          in ( (bhp > 0, bsymbol /= '@', bsymbol, bcolor, aid)
             , Color.AttrChar sattr $ if bhp > 0 then bsymbol else '%' )
      ours = filter (not . bproj . snd)
             $ actorAssocs (== side) drawnLevelId s
      maxViewed = width - 2
      -- Don't show anything if the only actor on the level is the leader.
      -- He's clearly highlighted on the level map, anyway.
      star = let sattr = case ES.size selected of
                   0 -> Color.defAttr {Color.fg = Color.BrBlack}
                   n | n == length ours ->
                     Color.defAttr {Color.bg = Color.Blue}
                   _ -> Color.defAttr
                 char = if length ours > maxViewed then '$' else '*'
             in Color.AttrChar sattr char
      viewed = take maxViewed $ sort $ map viewOurs ours
      addAttr t = map (Color.AttrChar Color.defAttr) (T.unpack t)
      allOurs = filter ((== side) . bfid) $ EM.elems $ sactorD s
      party = if length allOurs <= 1
              then []
              else [star] ++ map snd viewed ++ addAttr " "
  return $! party

drawPlayerName :: MonadClient m => Int -> m [Color.AttrChar]
drawPlayerName width = do
  let addAttr t = map (Color.AttrChar Color.defAttr) (T.unpack t)
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  let nameN n t =
        let fitWords [] = []
            fitWords l@(_ : rest) = if sum (map T.length l) + length l - 1 > n
                                    then fitWords rest
                                    else l
        in T.unwords $ reverse $ fitWords $ reverse $ T.words t
      ourName = nameN (width - 1) $ fname $ gplayer fact
  return $! if T.null ourName || T.length ourName >= width
            then []
            else addAttr $ ourName <> " "
