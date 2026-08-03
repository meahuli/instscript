"""
Strip prompt text from ComfyUI's in-RAM prompt history.

PromptQueue.task_done() stores the whole queue tuple, so history holds the API
graph (every widget value, including positive/negative prompt text) and
extra_data.extra_pnginfo.workflow (the full UI graph). GET /history serves all
of it unauthenticated. --disable-metadata does NOT cover this; it only governs
what gets embedded in saved image files.

This wraps task_done and blanks those two slots after the record is stored,
leaving "outputs" intact so blob ids stay reachable.

Off switch:  INLINE_PREVIEW_REDACT_HISTORY=0

This patches ComfyUI internals, so it is version-fragile by nature. Everything
below is built so that a shift in those internals fails LOUDLY and leaves
history untouched, rather than silently no-op'ing while looking healthy.
"""

import os
import logging
import inspect

log = logging.getLogger("inline_preview")

ENABLED = os.environ.get("INLINE_PREVIEW_REDACT_HISTORY", "1") not in ("0", "false", "False")

# task_done(self, item_id, history_result, status)
_EXPECTED_PARAMS = ["self", "item_id", "history_result", "status"]

_verified = False   # flipped once we've confirmed a real record came out blanked
_broken = False     # latched on first verification failure, so we warn once


def _redact_record(rec):
    """Blank the API graph (index 2) and extra_data (index 3) in place."""
    prompt = rec.get("prompt")
    if not isinstance(prompt, (list, tuple)) or len(prompt) < 4:
        return False
    scrubbed = list(prompt)
    scrubbed[2] = {}
    scrubbed[3] = {}
    rec["prompt"] = tuple(scrubbed) if isinstance(prompt, tuple) else scrubbed
    return True


def install():
    global _verified, _broken

    if not ENABLED:
        log.info("inline_preview: history redaction DISABLED "
                 "(INLINE_PREVIEW_REDACT_HISTORY=0) -- prompts stay in /history")
        return

    try:
        import execution
    except Exception as e:
        log.error("inline_preview: history redaction OFF -- cannot import execution (%s). "
                  "Prompts REMAIN readable via GET /history.", e)
        return

    queue_cls = getattr(execution, "PromptQueue", None)
    orig = getattr(queue_cls, "task_done", None)
    if orig is None:
        log.error("inline_preview: history redaction OFF -- execution.PromptQueue.task_done "
                  "not found. Prompts REMAIN readable via GET /history.")
        return

    if getattr(orig, "_inline_preview_patched", False):
        return

    try:
        params = list(inspect.signature(orig).parameters)
    except (TypeError, ValueError):
        params = None
    if params != _EXPECTED_PARAMS:
        log.error("inline_preview: history redaction OFF -- task_done signature is %s, "
                  "expected %s. ComfyUI internals changed; refusing to patch blindly. "
                  "Prompts REMAIN readable via GET /history.", params, _EXPECTED_PARAMS)
        return

    def task_done(self, item_id, history_result, status=None):
        global _verified, _broken

        # Read the prompt_id before the original runs -- task_done pops the
        # entry out of currently_running.
        prompt_id = None
        try:
            with self.mutex:
                running = self.currently_running.get(item_id)
            if isinstance(running, (list, tuple)) and len(running) > 1:
                prompt_id = running[1]
        except Exception as e:
            log.debug("inline_preview: could not read prompt_id (%s)", e)

        orig(self, item_id, history_result, status)

        if prompt_id is None:
            if not _broken:
                _broken = True
                log.error("inline_preview: history redaction FAILED -- could not identify the "
                          "finished prompt. PROMPTS ARE BEING STORED IN /history.")
            return

        try:
            with self.mutex:
                rec = self.history.get(prompt_id)
                if rec is None:
                    ok = False
                else:
                    ok = _redact_record(rec)
                    # Verify against the stored object, not our local copy.
                    if ok:
                        ok = self.history[prompt_id]["prompt"][2] == {}
        except Exception as e:
            ok = False
            log.debug("inline_preview: redaction raised (%s)", e)

        if ok:
            if not _verified:
                _verified = True
                log.info("inline_preview: history redaction active -- prompt graphs are "
                         "blanked in /history (outputs kept)")
        elif not _broken:
            _broken = True
            log.error("inline_preview: history redaction FAILED -- record shape changed. "
                      "PROMPTS ARE BEING STORED IN /history. Clear it with: "
                      "curl -X POST localhost:8188/history -H 'Content-Type: application/json' "
                      "-d '{\"clear\":true}'")

    task_done._inline_preview_patched = True
    task_done._inline_preview_orig = orig
    queue_cls.task_done = task_done
    log.info("inline_preview: history redaction installed (set "
             "INLINE_PREVIEW_REDACT_HISTORY=0 to keep prompts)")
