{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE TypeFamilies               #-}

module Servant.Server.UsingOtherConfigSpec where

import           Network.Wai
import           Test.Hspec (Spec, describe, it)
import           Test.Hspec.Wai

import Control.Concurrent (MVar, newMVar, readMVar)
import           Servant
import           Servant.Server.Internal.Config
import           Servant.Server.Internal.RoutingApplication


-- * Config

data CustomCombinator (a :: *)

instance forall subApi a .  (HasServer subApi) =>
  HasServer (CustomCombinator a :> subApi) where

  type ServerT (CustomCombinator a :> subApi) m =
    a -> ServerT subApi m
  type HasCfg (CustomCombinator a :> subApi) c =
    (HasConfigEntry c a, HasCfg subApi c)

  route Proxy config delayed =
    route subProxy config (fmap (inject config) delayed :: Delayed (Server subApi))
    where
      subProxy :: Proxy subApi
      subProxy = Proxy

      inject c f = f (getConfigEntry c)

-- * when you need to extract from a configuration param.

newtype TaggedApply tag a b = TaggedApply (a, a -> b)

appApply :: TaggedApply tag a b -> b
appApply (TaggedApply (a, f)) = f a

data CustomArrow tag (a :: *) (b :: *)

instance forall subApi a b tag . (HasServer subApi) =>
  HasServer (CustomArrow tag a b :> subApi) where

  type ServerT (CustomArrow tag a b :> subApi) m =
    b -> ServerT subApi m
  type HasCfg (CustomArrow tag a b :> subApi) c =
    (HasConfigEntry c (TaggedApply tag a b), HasCfg subApi c)

  route Proxy config delayed =
    route subProxy config (fmap (inject config) delayed :: Delayed (Server subApi))
      where
        subProxy :: Proxy subApi
        subProxy = Proxy

        inject c f = f (appApply (getConfigEntry c))

-- * API

data CustomConfig = CustomConfig String

type OneEntryAPI =
  CustomCombinator CustomConfig :> Get '[JSON] String

testServer :: Server OneEntryAPI
testServer (CustomConfig s) = return s

oneEntryApp :: Application
oneEntryApp =
  serve (Proxy :: Proxy OneEntryAPI) config testServer
  where
    config :: Config '[CustomConfig]
    config = CustomConfig "configValue" .:. EmptyConfig

type OneEntryTwiceAPI =
  "foo" :> CustomCombinator CustomConfig :> Get '[JSON] String :<|>
  "bar" :> CustomCombinator CustomConfig :> Get '[JSON] String

oneEntryTwiceApp :: Application
oneEntryTwiceApp = serve (Proxy :: Proxy OneEntryTwiceAPI) config $
  testServer :<|>
  testServer
  where
    config :: Config '[CustomConfig]
    config = CustomConfig "configValueTwice" .:. EmptyConfig

-- newtype wrap to provide two differnet configs.
newtype WrappedCustomConfig = WrappedCustomConfig {unWrapCustomConfig ::  CustomConfig }

type TwoDifferentEntries =
  "foo" :> CustomCombinator CustomConfig        :> Get '[JSON] String :<|>
  "bar" :> CustomCombinator WrappedCustomConfig :> Get '[JSON] String

twoDifferentEntries :: Application
twoDifferentEntries = serve (Proxy :: Proxy TwoDifferentEntries) config $
  testServer :<|>
  (testServer . unWrapCustomConfig)
  where
    config :: Config '[CustomConfig, WrappedCustomConfig]
    config =
      CustomConfig "firstConfigValue" .:.
      WrappedCustomConfig (CustomConfig "secondConfigValue") .:.
      EmptyConfig


-- using tagged apply to extract from same value.
data NameTag
data AgeTag
data User = User { name :: String, age :: Int }

type TwoEntrySameDep =
  "name" :> CustomArrow NameTag (MVar User) (IO String) :> Get '[JSON] String :<|>
  "age" :> CustomArrow AgeTag (MVar User) (IO Int)     :> Get '[JSON] Int

mkConfig :: MVar User
         -> Config (TaggedApply NameTag (MVar User) (IO String) ': TaggedApply AgeTag (MVar User) (IO Int) ': '[])
mkConfig mvarUser = TaggedApply (mvarUser, fmap name . readMVar)
                .:. TaggedApply (mvarUser, fmap age . readMVar)
                .:. EmptyConfig


twoEntrySameDep :: MVar User -> Application
twoEntrySameDep mvarUser = do
  let config = mkConfig mvarUser
  serve (Proxy :: Proxy TwoEntrySameDep) config $
    liftIO . fmap (++ "!!!") :<|> liftIO . fmap (+ 3)

-- * tests

spec :: Spec
spec =
  describe "using Config in a custom combinator" $ do
    with (return oneEntryApp) $
      it "allows to retrieve a ConfigEntry" $
        get "/" `shouldRespondWith` "\"configValue\""

    with (return oneEntryTwiceApp) $
      it "allows to retrieve the same ConfigEntry twice" $ do
        get "/foo" `shouldRespondWith` "\"configValueTwice\""
        get "/bar" `shouldRespondWith` "\"configValueTwice\""

    with (return twoDifferentEntries) $
      it "allows to retrieve different ConfigEntries for the same combinator" $ do
        get "/foo" `shouldRespondWith` "\"firstConfigValue\""
        get "/bar" `shouldRespondWith` "\"secondConfigValue\""

    with (fmap twoEntrySameDep (liftIO (newMVar (User "servant" 2)))) $
      it "allows two endpoints to both depend on the same data" $ do
        get "/name" `shouldRespondWith` "\"servant!!!\""
        get "/age" `shouldRespondWith` "5"