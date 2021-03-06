{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Neuron's route and its config
module Neuron.Web.Route where

import Data.GADT.Compare.TH (DeriveGEQ (deriveGEq))
import Data.GADT.Show.TH (DeriveGShow (deriveGShow))
import Data.Some (Some, withSome)
import Data.TagTree (Tag, unTag)
import Neuron.Zettelkasten.ID (Slug)
import Neuron.Zettelkasten.Zettel
  ( ZettelC,
    ZettelT (zettelTitle),
  )
import Reflex.Dom.Core (DomBuilder, elAttr, (=:))
import Relude

-- TODO: Do we even need a route GADT? Re-evaluate this when doing the rib->reflex-headless migration.
data Route a where
  Route_Zettel :: Slug -> Route ZettelC
  -- | Impulse is implemented in github.com/srid/rememorate
  -- The tag argument is only used in rendering the URL, and not when writing the file.
  -- TODO: Fix this bad use of types.
  Route_Impulse :: Maybe Tag -> Route ()

routeHtmlPath :: Route a -> FilePath
routeHtmlPath = \case
  Route_Impulse (Just tag) ->
    "impulse.html?q=tag:" <> toString (unTag tag)
  Route_Impulse Nothing ->
    "impulse.html"
  Route_Zettel slug ->
    toString slug <> ".html"

data RouteConfig t m = RouteConfig
  { -- | How to render a web route.
    routeConfigRouteLink :: DomBuilder t m => Some Route -> Map Text Text -> m () -> m (),
    -- | Get the URL for a web route as plain text
    routeConfigRouteURL :: Some Route -> Text
  }

routeConfig :: RouteConfig t m
routeConfig =
  RouteConfig renderRouteLink someRouteUrl
  where
    renderRouteLink someR attrs =
      elAttr "a" (attrs <> "href" =: someRouteUrl someR)
    someRouteUrl :: Some Route -> Text
    someRouteUrl sr =
      toText $ withSome sr routeHtmlPath

type NeuronWebT t m = ReaderT (RouteConfig t m) m

runNeuronWeb :: RouteConfig t m -> NeuronWebT t m a -> m a
runNeuronWeb = flip runReaderT

neuronRouteLink :: DomBuilder t m => Some Route -> Map Text Text -> m () -> NeuronWebT t m ()
neuronRouteLink someR attrs w = do
  f <- asks routeConfigRouteLink
  lift $ f someR attrs w

neuronRouteURL :: Monad m => Some Route -> NeuronWebT t m Text
neuronRouteURL someR = do
  f <- asks routeConfigRouteURL
  pure $ f someR

routeTitle' :: a -> Route a -> Text
routeTitle' v = \case
  Route_Impulse _mtag -> "Impulse"
  Route_Zettel _ ->
    either zettelTitle zettelTitle v

deriveGEq ''Route

deriveGShow ''Route
