{-
waymonad A wayland compositor in the spirit of xmonad
Copyright (C) 2017  Markus Ongyerth

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

Reach us at https://github.com/ongy/waymonad
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NumDecimals #-}
{-# LANGUAGE FlexibleContexts #-}
module Main
where

import Control.Applicative ((<|>))
import Control.Monad (when, void)
import Control.Monad.IO.Class (liftIO)
import Data.Monoid ((<>))
import Data.Text (Text)
import Foreign.Ptr (Ptr)
import System.IO
import System.Environment (lookupEnv)

import Text.XkbCommon.InternalTypes (Keysym(..))
import Text.XkbCommon.KeysymList
import Graphics.Wayland.WlRoots.Backend.Libinput (getDeviceHandle)
import Graphics.Wayland.WlRoots.Input (InputDevice, getDeviceName)
import Graphics.Wayland.WlRoots.Input.Keyboard (WlrModifier(..))
import Graphics.Wayland.WlRoots.Render.Color (Color (..))

import Data.String (IsString)
import Fuse.Main
import GlobalFilter
import Hooks.EnterLeave (enterLeaveHook)
import Hooks.FocusFollowPointer
import Hooks.KeyboardFocus
import Hooks.ScaleHook
import IdleManager
import Waymonad.Input (attachDevice)
import Waymonad.Input.Keyboard (setSubMap, resetSubMap, getSubMap)
import Layout.SmartBorders
import Layout.Choose
import Layout.Mirror (mkMirror, ToggleMirror (..))
import Layout.Spiral
import Layout.AvoidStruts
import Layout.Tall (Tall (..))
import Layout.ToggleFull (mkTFull, ToggleFullM (..))
import Layout.TwoPane (TwoPane (..))
import Layout.Ratio
import Navigation2D
import Output (Output (outputRoots), addOutputToWork, setPreferdMode)
import Protocols.GammaControl
import Protocols.Screenshooter
import Startup.Environment
import Startup.Generic
import Utility (doJust)
import Utility.Spawn (spawn, manageSpawnOn)
import View.Proxy (makeProxy)
import ViewSet (WSTag, Layouted, FocusCore, ListLike (..))
import WayUtil (sendMessage, focusNextOut, sendTo, killCurrent, closeCompositor)
import WayUtil.Current (getCurrentView)
import WayUtil.Floating (centerFloat)
import WayUtil.Timing
import WayUtil.View
import WayUtil.ViewSet (modifyFocusedWS)
import Waymonad (Way, KeyBinding)
import Waymonad.Types (SomeEvent, WayHooks (..), BindingMap)
import XMonad.ViewSet (ViewSet, sameLayout)

import qualified Data.Map as M

import qualified Hooks.OutputAdd as H
import qualified Hooks.SeatMapping as SM
import qualified Shells.XWayland as XWay
import qualified Shells.XdgShell as Xdg
import qualified Shells.WlShell as Wl
import qualified System.InputDevice as LI
import qualified View.Multi as Multi
import qualified Data.Text as T

import Waymonad.Main
import Config

import Graphics.Wayland.WlRoots.Util

setupTrackball :: Ptr InputDevice -> IO ()
setupTrackball dev = doJust (getDeviceHandle dev) $ \handle -> do
    name <- getDeviceName dev
    when ("Logitech USB Trackball" `T.isPrefixOf` name) $ do
        void $ LI.setScrollMethod handle LI.ScrollOnButtonDown
        void $ LI.setScrollButton handle 0x116

wsSyms :: [Keysym]
wsSyms =
    [ keysym_1
    , keysym_2
    , keysym_3
    , keysym_4
    , keysym_5
    , keysym_6
    , keysym_7
    , keysym_8
    , keysym_9
    , keysym_0
    , keysym_v
    ]

workspaces :: IsString a => [a]
workspaces = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "video"]

makeListNavigation :: (ListLike vs ws, FocusCore vs ws, WSTag ws)
                   => WlrModifier -> Way vs ws (BindingMap vs ws)
makeListNavigation modi = do
    let listNav = makeBindingMap
            [ (([modi], keysym_j), modifyFocusedWS $ flip _moveFocusRight)
            , (([modi], keysym_k), modifyFocusedWS $ flip _moveFocusLeft )
            , (([], keysym_Escape), resetSubMap)
            ]
    current <- getSubMap
    pure (M.union listNav current)


-- Use Logo as modifier when standalone, but Alt when started as child
getModi :: IO WlrModifier
getModi = do
    way <- lookupEnv "WAYLAND_DISPLAY"
    x11 <- lookupEnv "DISPLAY"
    pure . maybe Logo (const Alt) $ way <|> x11

bindings :: (Layouted vs ws, ListLike vs ws, FocusCore vs ws, IsString ws, WSTag ws)
         => WlrModifier -> [(([WlrModifier], Keysym), KeyBinding vs ws)]
bindings modi =
    [ (([modi], keysym_k), moveUp)
    , (([modi], keysym_j), moveDown)
    , (([modi], keysym_h), moveLeft)
    , (([modi], keysym_l), moveRight)
    , (([modi, Shift], keysym_k), modifyFocusedWS $ flip _moveFocusedLeft )
    , (([modi, Shift], keysym_j), modifyFocusedWS $ flip _moveFocusedRight)
    , (([modi, Shift], keysym_h), setSubMap =<< makeListNavigation modi)
    , (([modi], keysym_f), sendMessage ToggleFullM)
    , (([modi], keysym_m), sendMessage ToggleMirror)
    , (([modi], keysym_space), sendMessage NextLayout)
    , (([modi], keysym_Left), sendMessage $ DecreaseRatio 0.1)
    , (([modi], keysym_Right), sendMessage $ IncreaseRatio 0.1)

    , (([modi], keysym_Return), spawn "alacritty")
    , (([modi], keysym_d), spawn "dmenu_run")
    , (([modi], keysym_w), spawn "vwatch")
    , (([modi], keysym_t), spawn "mpc toggle")
    , (([modi, Shift], keysym_Left), spawn "mpc prev")
    , (([modi, Shift], keysym_Right), spawn "mpc next")

    , (([modi], keysym_n), focusNextOut)
    , (([modi], keysym_q), killCurrent)
    , (([modi], keysym_o), centerFloat)
    , (([modi], keysym_c), doJust getCurrentView makeProxy)
    , (([modi], keysym_a), doJust getCurrentView Multi.copyView)
    , (([modi, Shift], keysym_e), closeCompositor)
    ] ++ concatMap (\(sym, ws) -> [(([modi], sym), greedyView ws), (([modi, Shift], sym), sendTo ws), (([modi, Ctrl], sym), copyView ws)]) (zip wsSyms workspaces)

myEventHook :: (FocusCore vs a, WSTag a) => SomeEvent -> Way vs a ()
myEventHook = idleLog

myConf :: WlrModifier -> WayUserConf (ViewSet Text) Text
myConf modi = WayUserConf
    { wayUserConfWorkspaces  = workspaces
    , wayUserConfLayouts     = sameLayout . avoidStruts . mkSmartBorders 2 . mkMirror . mkTFull $ (Tall 0.5 ||| TwoPane 0.5 ||| Spiral 0.618)
    , wayUserConfManagehook  = XWay.overrideXRedirect <> manageSpawnOn
    , wayUserConfEventHook   = myEventHook
    , wayUserConfKeybinds    = bindings modi

    , wayUserConfInputAdd    = \ptr -> do
        liftIO $ setupTrackball ptr
        attachDevice ptr "seat0"
    , wayUserConfDisplayHook =
        [ getFuseBracket
        , getGammaBracket
        , getFilterBracket filterUser
        , baseTimeBracket
        , getStartupBracket (spawn "redshift -m wayland")
        , envBracket [ ("PULSE_SERVER", "zelda.ongy")
                     , ("QT_QPA_PLATFORM", "wayland-egl")
                     -- breaks firefox (on arch) :/
                     --, ("GDK_BACKEND", "wayland")
                     , ("SDL_VIDEODRIVER", "wayland")
                     , ("CLUTTER_BACKEND", "wayland")
                     ]
        ]
    , wayUserConfBackendHook = [getIdleBracket 3e5]
    , wayUserConfPostHook    = [getScreenshooterBracket]
    , wayUserConfCoreHooks   = WayHooks
        { wayHooksVWSChange       = wsScaleHook <> (liftIO . hPrint stderr)
        , wayHooksOutputMapping   = enterLeaveHook <> handlePointerSwitch <> SM.mappingChangeEvt <> constStrutHandler [("DVI-D-1", Struts 20 0 0 0)] <> (liftIO . hPrint stderr)
        , wayHooksSeatWSChange    = SM.wsChangeLogHook <> handleKeyboardSwitch <> (liftIO . hPrint stderr)
        , wayHooksSeatOutput      = SM.outputChangeEvt {-<> handleKeyboardPull-} <> (liftIO . hPrint stderr)
        , wayHooksSeatFocusChange = focusFollowPointer <> (liftIO . hPrint stderr)
        , wayHooksNewOutput       = H.outputAddHook
        }
    , wayUserConfShells = [Xdg.makeShell, Wl.makeShell, XWay.makeShellAct (spawn "monky | dzen2 -x 1280 -w 1280")]
    , wayUserConfLog = pure ()
    , wayUserConfOutputAdd = \out -> do
        setPreferdMode (outputRoots out)
        addOutputToWork out Nothing
    , wayUserconfLoggers = Nothing
    , wayUserconfColor = Color 0.5 0 0 1
    , wayUserconfColors = mempty
    }

main :: IO ()
main = do
    setLogPrio Debug
    modi <- getModi
    confE <- loadConfig
    case confE of
        Left err -> do
            hPutStrLn stderr "Couldn't load config:"
            hPutStrLn stderr err
        Right conf -> wayUserMain $ modifyConfig conf (myConf modi)