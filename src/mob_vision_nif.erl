%% mob_vision_nif — Erlang NIF module for the on-device OCR / text-recognition
%% tier-1 plugin.
%%
%% iOS: priv/native/ios/mob_vision_nif.m (Objective-C: the Vision framework,
%% VNRecognizeTextRequest, on a CGImage loaded from the file path). Android:
%% priv/native/jni/mob_vision_nif.zig bridging to io.mob.vision.MobVisionBridge
%% (ML Kit text-recognition via InputImage.fromFilePath). Both register this
%% module via ERL_NIF_INIT and are statically linked into the host binary on
%% device. On a host dev build neither is linked, so on_load tolerates the
%% failure and the NIF falls back to nif_error until the native merge links one.
-module(mob_vision_nif).
-export([recognize_text/1]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_vision_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

recognize_text(_ReqJson) ->
    erlang:nif_error(nif_not_loaded).
