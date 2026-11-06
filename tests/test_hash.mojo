# mojoui.hash against FIPS 180-4's vectors and lengths around the padding edges (55/56/64 bytes), compared with hashlib.
from mojoui.hash import sha256_hex


def check(text: String, want: String) raises:
    var got = sha256_hex(text)
    if got != want:
        raise Error("sha256(" + String(text.byte_length()) + " bytes): " + got + ", want " + want)


def main() raises:
    check("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    check("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    check("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    check("a" * 55, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
    check("a" * 56, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
    check("a" * 64, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    check("mst-é ✓", "5fddf889d594b9a782ae0845008961046c4d2c5d4774042f13bf7bdef9287e88")
    print("hash: ok")
