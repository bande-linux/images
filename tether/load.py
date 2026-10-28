import os, runpy, sys
import unboot.proxy

chosen = [a.split("=", 1) for a in os.environ.get("CHOSEN", "").split()]
set_chosen = unboot.proxy.UNBOOTProxy.kboot_set_chosen


def kboot_set_chosen(self, name, value):
    set_chosen(self, name, value)
    if name == "bootargs":
        for k, v in chosen:
            set_chosen(self, k, v)


unboot.proxy.UNBOOTProxy.kboot_set_chosen = kboot_set_chosen
sys.argv = ["linux.py"] + sys.argv[1:]
runpy.run_path("tools/linux.py", run_name="__main__")
