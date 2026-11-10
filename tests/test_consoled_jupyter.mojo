# Run in Jupyter (D-6501), offline: the notebook file it writes (nbformat 4.5, read back unchanged by the saved view,
# never overwritten, never outside MXC_HOME/notebooks), the Jupyter command (loopback only, no port hopping, framed
# only by the console) and the links it answers with.
#   scripts/mojo_flare.sh build -I examples/consoled tests/test_consoled_jupyter.mojo -o build/test_consoled_jupyter
from std.os import makedirs, setenv
from std.os.path import exists
from mojoui.json import Json
from mojoui.files import remove_tree
from learn import ensure_ipynb, notebook_json, read_text
from jupyter import Jupyter, jupyter_argv

comptime HOME = "build/test_consoled_jupyter"


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    remove_tree(HOME)
    makedirs(HOME, exist_ok=True)
    # a model with no local files still gets a notebook: the Try it cells and the card's placeholder
    var file = ensure_ipynb("tiny-model", "owner/tiny", "abc", HOME + "/nowhere", HOME, 11435)
    check(file == "tiny-model.ipynb", "file name " + file)
    var path = HOME + "/notebooks/" + file
    var nb = Json.parse(read_text(path))
    check(nb.number(nb.get(0, "nbformat")) == 4 and nb.number(nb.get(0, "nbformat_minor")) == 5, "nbformat 4.5")
    var cells = nb.get(0, "cells")
    var code = 0
    for i in range(nb.size(cells)):
        var c = nb.at(cells, i)
        check(nb.text(nb.get(c, "id")) == "cell-" + String(i), "cell id")
        if nb.text(nb.get(c, "cell_type")) == "code":
            code += 1
            check(nb.get(c, "outputs") >= 0 and nb.get(c, "execution_count") >= 0, "a code cell's outputs and count")
    check(code >= 3, "the Try it cells")
    check(nb.get(nb.get(nb.get(0, "metadata"), "mxconsole"), "architecture") >= 0, "the architecture in metadata")
    # the saved view reads the written file back as is
    var back = Json.parse(notebook_json("tiny-model", "owner/tiny", "abc", HOME + "/nowhere", HOME, 11435))
    check(not back.flag(back.get(0, "generated")), "read back as a saved notebook")
    check(back.size(back.get(0, "cells")) == nb.size(cells), "same cells read back")
    # an existing notebook (the owner's edits) is never overwritten
    with open(path, "w") as f:
        f.write('{"cells": [], "metadata": {}, "nbformat": 4, "nbformat_minor": 5, "mine": true}')
    _ = ensure_ipynb("tiny-model", "owner/tiny", "abc", HOME + "/nowhere", HOME, 11435)
    check(read_text(path).find('"mine": true') >= 0, "overwrote an existing notebook")
    # a name can't leave the notebooks folder
    for bad in ["../x", "a/b", ".hidden", ""]:
        var refused = False
        try:
            _ = ensure_ipynb(String(bad), "o/r", "abc", HOME, HOME, 11435)
        except:
            refused = True
        check(refused, "accepted the notebook name " + String(bad))
    check(not exists(HOME + "/x.ipynb"), "wrote outside the notebooks folder")
    # the command: MXC_JUPYTER first, loopback, a fixed port, framed only by the console's own origins
    _ = setenv("MXC_JUPYTER", "/opt/jl/bin/jupyter", True)
    var argv = jupyter_argv(HOME + "/notebooks", 40001, 11435)
    check(argv[0] == "/opt/jl/bin/jupyter" and argv[1] == "lab", "MXC_JUPYTER is the command")
    var joined = String("")
    for a in argv:
        joined += a + " "
    for want in ["--ServerApp.ip=127.0.0.1", "--ServerApp.port=40001", "--ServerApp.port_retries=0", "--no-browser",
                 "frame-ancestors 'self' http://127.0.0.1:11435 http://localhost:11435"]:
        check(joined.find(String(want)) >= 0, "missing " + String(want))
    # the links: the lab view for a browser, the single-document view for the console's frame, the name encoded
    var j = Jupyter()
    j.port = 40001
    j.token = "tok"
    var reply = Json.parse(j.reply("a b.ipynb", "/x/a b.ipynb"))
    check(reply.text(reply.get(0, "url")) == "http://127.0.0.1:40001/lab/tree/a%20b.ipynb?token=tok", "url")
    check(reply.text(reply.get(0, "embed_url")) == "http://127.0.0.1:40001/doc/tree/a%20b.ipynb?token=tok", "embed_url")
    remove_tree(HOME)
    print("test_consoled_jupyter: PASS")
