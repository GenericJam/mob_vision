/* mob_vision_nif — iOS on-device OCR tier-1 plugin NIF (Objective-C).
 *
 * Runs the Vision framework (VNRecognizeTextRequest) on a CGImage loaded from
 * an image FILE path — no camera, no photo-library access, no permission.
 * Compiled as ObjC (-fobjc-arc) via the plugin objc-NIF path (manifest
 * lang: :objc).
 *
 * Delivered message shapes:
 *   text  -> {vision, text,  <<utf8>>}   (full recognized text; "" if none)
 *   error -> {vision, error, <<reason>>} (e.g. "no_image")
 *
 * The request arg is JSON {"path": "...", "languages": [...]}; parsed with
 * NSJSONSerialization. Recognition runs on a background queue (Vision is
 * synchronous and can be slow), delivering asynchronously to the caller pid.
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#include <erl_nif.h>

// Deliver {vision, <tag>, <utf8 binary>} to `pid`.
static void vision_send(ErlNifPid pid, const char *tag, NSString *s) {
    ErlNifEnv *e = enif_alloc_env();
    const char *utf8 = s ? [s UTF8String] : "";
    if (!utf8)
        utf8 = "";
    size_t len = strlen(utf8);
    ErlNifBinary bin;
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, utf8, len);
    ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "vision"), enif_make_atom(e, tag),
                                        enif_make_binary(e, &bin));
    enif_send(NULL, &pid, e, msg);
    enif_free_env(e);
}

static void vision_recognize(ErlNifPid pid, NSString *path, NSArray<NSString *> *languages) {
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img || !img.CGImage) {
        vision_send(pid, "error", @"no_image");
        return;
    }

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage
                                                                            options:@{}];

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc]
        initWithCompletionHandler:^(VNRequest *request, NSError *error) {
          if (error) {
              vision_send(pid, "error", error.localizedDescription ?: @"recognition_failed");
              return;
          }
          NSMutableArray<NSString *> *lines = [NSMutableArray array];
          for (VNRecognizedTextObservation *obs in request.results) {
              VNRecognizedText *top = [[obs topCandidates:1] firstObject];
              if (top.string)
                  [lines addObject:top.string];
          }
          vision_send(pid, "text", [lines componentsJoinedByString:@"\n"]);
        }];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = YES;
    if (languages.count > 0)
        req.recognitionLanguages = languages;

    NSError *err = nil;
    [handler performRequests:@[ req ] error:&err];
    if (err)
        vision_send(pid, "error", err.localizedDescription ?: @"recognition_failed");
}

static ERL_NIF_TERM nif_recognize_text(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifPid pid;
    enif_self(env, &pid);

    ErlNifBinary req;
    if (!enif_inspect_binary(env, argv[0], &req) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &req))
        return enif_make_badarg(env);

    NSData *data = [NSData dataWithBytes:req.data length:req.size];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSString *path = [json isKindOfClass:[NSDictionary class]] ? json[@"path"] : nil;
    NSArray *langs = [json isKindOfClass:[NSDictionary class]] ? json[@"languages"] : @[];
    if (![path isKindOfClass:[NSString class]]) {
        vision_send(pid, "error", @"bad_request");
        return enif_make_atom(env, "ok");
    }
    if (![langs isKindOfClass:[NSArray class]])
        langs = @[];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      vision_recognize(pid, path, langs);
    });
    return enif_make_atom(env, "ok");
}

static ErlNifFunc nif_funcs[] = {
    {"recognize_text", 1, nif_recognize_text, 0},
};

ERL_NIF_INIT(mob_vision_nif, nif_funcs, NULL, NULL, NULL, NULL)
