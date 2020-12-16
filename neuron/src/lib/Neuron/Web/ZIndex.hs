{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Neuron.Web.ZIndex
  ( renderZIndex,
    buildZIndex,
    ZIndex (..),
    style,
  )
where

import Clay (Css, em, (?))
import qualified Clay as C
import Control.Monad.Fix (MonadFix)
import Data.Foldable (maximum)
import qualified Data.Map.Strict as Map
import Data.TagTree (mkTagPattern)
import qualified Data.Text as T
import Data.Tree (Forest, Tree (..))
import qualified Neuron.Web.Query.View as QueryView
import Neuron.Web.Route (NeuronWebT)
import qualified Neuron.Web.Theme as Theme
import Neuron.Web.Widget (divClassVisible, elPreOverflowing, elVisible)
import Neuron.Web.Zettel.View (renderZettelParseError)
import Neuron.Zettelkasten.Connection (Connection (Folgezettel))
import Neuron.Zettelkasten.Graph (ZettelGraph)
import qualified Neuron.Zettelkasten.Graph as G
import Neuron.Zettelkasten.ID (ZettelID (..))
import Neuron.Zettelkasten.Query (zettelsByTag)
import Neuron.Zettelkasten.Query.Error (showQueryResultError)
import Neuron.Zettelkasten.Zettel
  ( Zettel,
    ZettelError (..),
    ZettelT (zettelTitle),
  )
import Reflex.Dom.Core hiding (mapMaybe, (&))
import Relude hiding ((&))

-- | The value needed to render the z-index
--
-- All heavy graph computations are decoupled from rendering, producing this
-- value, that is in turn used for instant rendering.
data ZIndex = ZIndex
  { -- | Clusters on the folgezettel graph.
    zIndexClusters :: [Forest (Zettel, [Zettel])],
    zIndexOrphans :: [Zettel],
    -- | All zettel errors
    zIndexErrors :: Map ZettelID (NonEmpty ZettelError),
    zIndexStats :: Stats,
    zPinned :: [Zettel]
  }

data Stats = Stats
  { statsZettelCount :: Int,
    statsZettelConnectionCount :: Int
  }
  deriving (Eq, Show)

data TreeMatch
  = -- | Tree's root matches the query.
    -- Subtrees may or may not match.
    TreeMatch_Root
  | -- | Tree's root does not match.
    -- However, one of the subtrees match.
    TreeMatch_Under
  deriving (Eq, Show)

searchTree :: (a -> Bool) -> Tree a -> Maybe (Tree (TreeMatch, a))
searchTree f (Node x children) = do
  let children' = catMaybes $ searchTree f <$> children
      tm
        | f x = Just TreeMatch_Root
        | null children' = Nothing
        | otherwise = Just TreeMatch_Under
  m <- tm
  pure $ Node (m, x) children'

buildZIndex :: ZettelGraph -> Map ZettelID (NonEmpty ZettelError) -> ZIndex
buildZIndex graph errors =
  let (orphans, clusters) = partitionEithers $
        flip fmap (G.categoryClusters graph) $ \case
          [Node z []] -> Left z -- Orphans (cluster of exactly one)
          x -> Right x
      clustersWithUplinks :: [Forest (Zettel, [Zettel])] =
        -- Compute backlinks for each node in the tree.
        flip fmap clusters $ \(zs :: [Tree Zettel]) ->
          G.backlinksMulti Folgezettel zs graph
      stats = Stats (length $ G.getZettels graph) (G.connectionCount graph)
      pinnedZettels = zettelsByTag (G.getZettels graph) [mkTagPattern "pinned"]
   in ZIndex (fmap sortCluster clustersWithUplinks) orphans errors stats pinnedZettels
  where
    -- TODO: Either optimize or get rid of this (or normalize the sorting somehow)
    sortCluster fs =
      sortZettelForest $
        flip fmap fs $ \Node {..} ->
          Node rootLabel $ sortZettelForest subForest
    -- Sort zettel trees so that trees containing the most recent zettel (by ID) come first.
    sortZettelForest = sortOn (Down . maximum)

renderZIndex ::
  (DomBuilder t m, PostBuild t m, MonadHold t m, MonadFix m) =>
  Theme.Theme ->
  ZIndex ->
  -- | Search query to filter
  Dynamic t (Maybe Text) ->
  NeuronWebT t m ()
renderZIndex (Theme.semanticColor -> themeColor) ZIndex {..} mqDyn = do
  elClass "h1" "header" $ text "Zettel Index"
  elVisible (isNothing <$> mqDyn) $
    elClass "details" "ui tiny errors message" $ do
      el "summary" $ text "Errors"
      renderErrors zIndexErrors
  dyn_ $
    ffor mqDyn $ \mq -> forM_ mq $ \q ->
      divClass "ui message" $ do
        text $ "Filtering by query: " <> q
  divClass "z-index" $ do
    let pinned = ffor mqDyn $ \mq -> filter (matchZettel mq) zPinned
    divClassVisible (not . null <$> pinned) "ui pinned raised segment" $ do
      elClass "h3" "ui header" $ text "Pinned"
      el "ul" $
        void $
          simpleList pinned $ \zDyn ->
            dyn_ $ ffor zDyn zettelLink
    let orphans = ffor mqDyn $ \mq -> filter (matchZettel mq) zIndexOrphans
    divClassVisible (not . null <$> orphans) "ui piled segment" $ do
      elClass "p" "info" $ do
        text "Notes without any "
        elAttr "a" ("href" =: "https://neuron.zettel.page/linking.html") $ text "folgezettel"
        text " relationships"
      el "ul" $
        void $
          simpleList orphans $ \zDyn ->
            dyn_ $ ffor zDyn zettelLink
    let clusters = ffor mqDyn $ \mq ->
          ffor zIndexClusters $ \forest ->
            fforMaybe forest $ \tree -> do
              searchTree (matchZettel mq . fst) tree
    void $
      simpleList clusters $ \forestDyn ->
        divClassVisible (not . null <$> forestDyn) ("ui " <> themeColor <> " segment") $ do
          el "ul" $ renderForest forestDyn
    el "p" $ do
      text $
        "The zettelkasten has "
          <> countNounBe "zettel" "zettels" (statsZettelCount zIndexStats)
          <> " and "
          <> countNounBe "link" "links" (statsZettelConnectionCount zIndexStats)
      text $ ". It has " <> countNounBe "cluster" "clusters" (length zIndexClusters) <> " in its folgezettel graph. "
      text "Each cluster's "
      elAttr "a" ("href" =: "https://neuron.zettel.page/folgezettel-heterarchy.html") $ text "folgezettel heterarchy"
      text " is rendered as a forest."
  where
    countNounBe noun nounPlural = \case
      1 -> "1 " <> noun
      n -> show n <> " " <> nounPlural
    matchZettel :: Maybe Text -> Zettel -> Bool
    matchZettel mq z =
      isNothing $ do
        q <- mq
        guard $ not $ T.toLower q `T.isInfixOf` T.toLower (zettelTitle z)

renderErrors :: DomBuilder t m => Map ZettelID (NonEmpty ZettelError) -> NeuronWebT t m ()
renderErrors errors = do
  let severity = \case
        ZettelError_ParseError _ -> "negative"
        ZettelError_QueryResultErrors _ -> "warning"
        ZettelError_AmbiguousID _ -> "negative"
        ZettelError_AmbiguousSlug _ -> "negative"
      errorMessageHeader zid = \case
        ZettelError_ParseError (slug, _) -> do
          text "Zettel "
          QueryView.renderZettelLinkIDOnly zid slug
          text " failed to parse"
        ZettelError_QueryResultErrors (slug, _) -> do
          text "Zettel "
          QueryView.renderZettelLinkIDOnly zid slug
          text " has missing wiki-links"
        ZettelError_AmbiguousID _files -> do
          text $
            "More than one file define the same zettel ID ("
              <> unZettelID zid
              <> "):"
        ZettelError_AmbiguousSlug _slug -> do
          text $ "Zettel '" <> unZettelID zid <> "' ignored; has ambiguous slug"

  forM_ (Map.toList errors) $ \(zid, zErrors) ->
    forM_ zErrors $ \zError -> do
      divClass ("ui tiny message " <> severity zError) $ do
        divClass "header" $ errorMessageHeader zid zError
        el "p" $ do
          case zError of
            ZettelError_ParseError (_slug, parseError) ->
              renderZettelParseError parseError
            ZettelError_QueryResultErrors queryErrors ->
              el "ol" $ do
                forM_ (snd queryErrors) $ \qe ->
                  el "li" $ elPreOverflowing $ text $ showQueryResultError qe
            ZettelError_AmbiguousID filePaths ->
              el "ul" $ do
                forM_ filePaths $ \fp ->
                  el "li" $ el "tt" $ text $ toText fp
            ZettelError_AmbiguousSlug slug ->
              el "p" $ text $ "Slug '" <> slug <> "' is used by another zettel"

renderForest ::
  (DomBuilder t m, MonadHold t m, PostBuild t m, MonadFix m) =>
  Dynamic t [Tree (TreeMatch, (Zettel, [Zettel]))] ->
  NeuronWebT t m ()
renderForest treesDyn = do
  void $
    simpleList treesDyn $ \treeDyn -> do
      mDyn <- holdUniqDyn $ ffor treeDyn $ \(Node (m, _) _) -> m
      subtreesDyn <- holdUniqDyn $ ffor treeDyn $ \(Node _ subtrees) -> subtrees
      zup <- holdUniqDyn $ ffor treeDyn $ \(Node (_, x) _) -> x
      elDynClass "span" (ffor mDyn $ \m -> if m == TreeMatch_Root then "q root" else "q under") $ do
        dyn_ $
          ffor zup $ \(zettel, uplinks) -> do
            zettelLink zettel
            when (length uplinks >= 2) $ do
              elClass "span" "uplinks" $ do
                forM_ uplinks $ \z2 -> do
                  el "small" $
                    elAttr "i" ("class" =: "linkify icon" <> "title" =: zettelTitle z2) blank
        el "ul" $ renderForest subtreesDyn

zettelLink :: DomBuilder t m => Zettel -> NeuronWebT t m ()
zettelLink z = do
  el "li" $ QueryView.renderZettelLink Nothing Nothing def z

style :: Css
style = do
  "div.z-index" ? do
    "p.info" ? do
      C.color C.gray
    C.ul ? do
      C.listStyleType C.square
      C.paddingLeft $ em 1.5
    ".uplinks" ? do
      C.marginLeft $ em 0.3
  ".errors" ? do
    blank
  -- Display non-matching parents of matching nodes deemphasized
  ".q.under > li > span.zettel-link-container span.zettel-link a" ? do
    C.important $ C.color C.gray
