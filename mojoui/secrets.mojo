# mojoui.secrets: one small secret (an API key, a token) kept in the system's own secret store, never in a plain file
# (goal 82 M6). Linux: the Secret Service (GNOME Keyring, KWallet) through libsecret's own `secret-tool`; macOS: the login
# keychain through `security`. The value goes to the tool on its stdin and comes back on its stdout, both through pipes
# (mojoui.process.exchange): never on a command line (where `ps` would show it), never in a file, never in an error
# message or a log line.
#
#   var store = SecretStore("Personal Note AI")
#   store.save("api-key", key)            # raises with a reason (no keyring running, the keychain locked), never the key
#   var key = store.load("api-key")       # "" when nothing is saved
#   store.has("api-key"); store.forget("api-key")
#
# Why the tools and not the C APIs: libsecret's store/lookup calls are C varargs (attribute pairs ending in NULL), which
# Mojo's FFI can't call, and the keychain's SecItem calls take CFDictionaries of framework constants; both tools are
# shipped with the store itself (libsecret's package; macOS), so the trusted code that talks to the store is the store's
# own (D-8701). Windows, Android, iPhone, the web: not built (save raises "no secret store on this host").

from mojoui.process import exchange, Exchanged
from std.sys import CompilationTarget

comptime _MAX = 4096  # a key, a token: never a document


def _printable(value: String) -> Bool:
    for b in value.as_bytes():
        if b < 0x20 or b == 0x7F:
            return False
    return True


def _mac_quoted(value: String) raises -> String:
    """A word for `security -i`'s own command reader: double-quoted; a value with a quote or a backslash in it is refused
    (keys and tokens never have one) rather than escaped in a way the reader might read differently."""
    for b in value.as_bytes():
        if b == UInt8(ord('"')) or b == UInt8(ord("\\")):
            raise Error("the value has a quote or a backslash, which this store can't take")
    return '"' + value + '"'


struct SecretStore(Copyable, Movable):
    var service: String  # the app's name for its secrets ("Personal Note AI"): the item's service / attribute
    var keychain: String  # macOS: a keychain file instead of the login keychain ("": the login one); a test's own, unlocked

    def __init__(out self, service: String, keychain: String = ""):
        self.service = service
        self.keychain = keychain

    def where(self) -> String:
        """Where the secrets go, in words for a settings page."""
        comptime if CompilationTarget.is_linux():
            return "the system keyring (Secret Service)"
        elif CompilationTarget.is_macos():
            return ("the keychain " + self.keychain) if self.keychain != "" else "the login keychain"
        else:
            return "nowhere: no secret store on this host"

    def save(self, account: String, value: String) raises:
        if value == "" or value.byte_length() > _MAX or not _printable(value):
            raise Error("that doesn't look like a key (empty, too long, or with a line break in it)")
        var r: Exchanged
        comptime if CompilationTarget.is_linux():
            r = exchange(["secret-tool", "store", "--label=" + self.service + " (" + account + ")", "service", self.service, "account", account], value)
            if r.code != 0:
                raise Error("the keyring didn't take it (is a Secret Service such as GNOME Keyring running and unlocked?)" if r.code > 0 else "secret-tool isn't installed (it comes with libsecret)")
        elif CompilationTarget.is_macos():
            var line = "add-generic-password -U -s " + _mac_quoted(self.service) + " -a " + _mac_quoted(account) + " -w " + _mac_quoted(value) + ((" " + _mac_quoted(self.keychain)) if self.keychain != "" else "") + "\n"
            r = exchange(["/usr/bin/security", "-i"], line)
            if r.code != 0 or not self.has(account):
                raise Error("the login keychain didn't take it (is it locked? unlock it in Keychain Access, or sign in at the Mac)")
        else:
            raise Error("no secret store on this host")

    def load(self, account: String) raises -> String:
        """The saved value, or "" when there is none. Raises only when the store can't be asked."""
        var r: Exchanged
        comptime if CompilationTarget.is_linux():
            r = exchange(["secret-tool", "lookup", "service", self.service, "account", account], "")
            if r.code < 0:
                raise Error("secret-tool isn't installed (it comes with libsecret), or the keyring didn't answer")
        elif CompilationTarget.is_macos():
            var argv: List[String] = ["/usr/bin/security", "find-generic-password", "-s", self.service, "-a", account, "-w"]
            if self.keychain != "":
                argv.append(self.keychain)
            r = exchange(argv, "")
            if r.code < 0:
                raise Error("the keychain didn't answer")
        else:
            raise Error("no secret store on this host")
        if r.code != 0:
            return ""
        var v = r.out
        while v.endswith("\n") or v.endswith("\r"):
            var cut = String(v[byte = 0 : v.byte_length() - 1])
            v = cut^
        return v^

    def has(self, account: String) -> Bool:
        try:
            return self.load(account) != ""
        except:
            return False

    def forget(self, account: String) raises:
        """Removes the saved value (nothing saved: no error)."""
        var r: Exchanged
        comptime if CompilationTarget.is_linux():
            r = exchange(["secret-tool", "clear", "service", self.service, "account", account], "")
        elif CompilationTarget.is_macos():
            var argv: List[String] = ["/usr/bin/security", "delete-generic-password", "-s", self.service, "-a", account]
            if self.keychain != "":
                argv.append(self.keychain)
            r = exchange(argv, "")
        else:
            raise Error("no secret store on this host")
        if r.code < 0:
            raise Error("the secret store didn't answer")
        if self.has(account):
            raise Error("the secret store kept it")
