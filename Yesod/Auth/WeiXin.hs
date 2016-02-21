{-# LANGUAGE ScopedTypeVariables #-}
module Yesod.Auth.WeiXin
  ( wxAuthPluginName
  , wxAuthDummyPluginName
  , YesodAuthWeiXin(..)
  , authWeixin
  , authWeixinDummy
  ) where

import ClassyPrelude.Yesod
import Yesod.Core.Types                     (HandlerContents(HCError))
import Yesod.Auth
import qualified Yesod.Auth.Message as Msg

import WeiXin.PublicPlatform

wxAuthPluginName :: Text
wxAuthPluginName = "weixin"

wxAuthDummyPluginName :: Text
wxAuthDummyPluginName = "weixin-dummy"

loginCallbackInR :: AuthRoute
loginCallbackInR = PluginR wxAuthPluginName ["wxcb", "in"]

loginCallbackOutR :: AuthRoute
loginCallbackOutR = PluginR wxAuthPluginName ["wxcb", "out"]

loginDummyR :: AuthRoute
loginDummyR = PluginR wxAuthDummyPluginName ["login"]


class (YesodAuth site) => YesodAuthWeiXin site where

  -- | The config for OAuth wthin WeiXin client
  -- 用于微信客户端内打开网页时的认证
  wxAuthConfigInsideWX :: HandlerT site IO WxppAuthConfig

  -- | The config for OAuth outside WeiXin client
  -- 用于普通浏览器内打开网页时的认证
  wxAuthConfigOutsideWX :: HandlerT site IO WxppAuthConfig


authWeixin :: forall m. YesodAuthWeiXin m => AuthPlugin m
authWeixin =
  AuthPlugin wxAuthPluginName dispatch loginWidget
  where
    dispatch "POST" ["wxcb", "out" ]  = getLoginCallbackOutR >>= sendResponse
    dispatch "POST" ["wxcb", "in" ]   = getLoginCallbackInR >>= sendResponse
    dispatch _ _ = notFound

    loginWidget :: (Route Auth -> Route m) -> WidgetT m IO ()
    loginWidget toMaster = do
      in_wx <- isJust <$> handlerGetWeixinClientVersion
      (auth_config, mk_url, cb_route) <-
            if in_wx
              then do
                let scope = AS_SnsApiBase
                (, flip wxppOAuthRequestAuthInsideWx scope, loginCallbackInR)
                    <$> handlerToWidget wxAuthConfigInsideWX
              else do
                (, wxppOAuthRequestAuthOutsideWx, loginCallbackOutR)
                    <$> handlerToWidget wxAuthConfigOutsideWX
      render_url <- getUrlRender
      let callback_url = UrlText $ render_url (toMaster cb_route)
      let app_id = wxppAuthAppID auth_config
      state <- wxppOAuthMakeRandomState app_id
      let auth_url = mk_url app_id callback_url state
      redirect auth_url


authWeixinDummy :: (YesodAuth m, RenderMessage m FormMessage) => AuthPlugin m
authWeixinDummy =
  AuthPlugin wxAuthDummyPluginName dispatch loginWidget
  where
    dispatch "POST" ["login"] = postLoginDummyR >>= sendResponse
    dispatch _ _ = notFound

    loginWidget toMaster =
      [whamlet|
        $newline never
        <form method="post" action="@{toMaster loginDummyR}">
          <table>
            <tr>
              <th>App Id
              <td>
                 <input type="text" name="app_id" required>
            <tr>
              <th>Open Id
              <td>
                 <input type="text" name="open_id" required>
            <tr>
              <th>union Id
              <td>
                 <input type="text" name="union_id" required>
            <tr>
              <td colspan="2">
                <button type="submit" .btn .btn-success>_{Msg.LoginTitle}
      |]

getLoginCallbackInR :: YesodAuthWeiXin master
                    => HandlerT Auth (HandlerT master IO) TypedContent
getLoginCallbackInR = do
    lift wxAuthConfigInsideWX >>= getLoginCallbackReal

getLoginCallbackOutR :: YesodAuthWeiXin master
                    => HandlerT Auth (HandlerT master IO) TypedContent
getLoginCallbackOutR = do
    lift wxAuthConfigOutsideWX >>= getLoginCallbackReal

logSource :: Text
logSource = "WeixinAuthPlugin"

getLoginCallbackReal :: YesodAuthWeiXin master
                    => WxppAuthConfig
                    -> HandlerT Auth (HandlerT master IO) TypedContent
getLoginCallbackReal auth_config = do
    m_code <- lookupGetParam "code"
    let app_id = wxppAuthAppID auth_config
        secret = wxppAuthAppSecret auth_config

    oauth_state <- liftM (fromMaybe "") $ lookupGetParam "state"
    m_expected_state <- lookupSession (sessionKeyWxppOAuthState app_id)
    unless (m_expected_state == Just oauth_state) $ do
        $logErrorS logSource $
            "OAuth state check failed, got: " <> oauth_state
        permissionDenied "Invalid State"

    case fmap OAuthCode m_code of
        Just code | not (null $ unOAuthCode code) -> do
            -- 用户同意授权
            err_or_atk_info <- tryWxppWsResult $ wxppOAuthGetAccessToken app_id secret code
            atk_info <- case err_or_atk_info of
                            Left err -> do
                                $logErrorS logSource $
                                    "wxppOAuthGetAccessToken failed: " <> tshow err
                                throwM $ HCError $ InternalError "微信服务接口错误，请稍后重试"

                            Right x -> return x

            let open_id = oauthAtkOpenID atk_info
                m_union_id = oauthAtkUnionID atk_info

            sessionMarkWxppUser app_id open_id m_union_id
            ident <- case m_union_id of
                      Nothing -> do
                        $logErrorS logSource "No Union Id available"
                        throwM $ HCError $ InternalError "微信服务配置错误，请稍后重试"
                      Just uid -> return $ unWxppUnionID uid

            lift $ setCredsRedirect (Creds wxAuthPluginName ident [])

        _ -> do
            permissionDenied "用户拒绝授权"


postLoginDummyR :: (YesodAuth master, RenderMessage master FormMessage)
                  => HandlerT Auth (HandlerT master IO) TypedContent
postLoginDummyR = do
  (app_id0, open_id0, m_union_id0) <- lift $ runInputPost $ do
                          (,,) <$> ireq textField "app_id"
                              <*> ireq textField "open_id"
                              <*> iopt textField "union_id"
  let open_id = WxppOpenID open_id0
      app_id = WxppAppID app_id0
      m_union_id = WxppUnionID <$> m_union_id0

  sessionMarkWxppUser app_id open_id m_union_id

  foundation <- lift getYesod
  lift $ redirectUltDest (loginDest foundation)
