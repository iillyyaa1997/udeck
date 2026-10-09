"""The lab's own Ed25519 verifier, held to RFC 8032's test vectors and to an independent implementation.

The lab checks a published release's zip against its own appcast before the zip
goes anywhere near a guest (`releases.verify`), and this is the check. A verifier
that says yes to everything would let a damaged or substituted download through
looking exactly like a release that holds — so most of what follows is about
the noes.
"""

import hashlib
import os

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from udeck_e2e import ed25519

# RFC 8032, 7.1: TEST 1, TEST 2, TEST 3 and TEST SHA(abc) — secret key, public key,
# message and signature, as the RFC prints them. The secret keys are here so that
# the test can also say the independent implementation agrees with the RFC.
VECTORS = [
    (
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        "",
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
    ),
    (
        "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
        "72",
        "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
    ),
    (
        "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
        "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
        "af82",
        "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
    ),
    (
        "833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
        "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
        hashlib.sha512(b"abc").hexdigest(),
        "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704",
    ),
]

# The order of the base point (RFC 8032, 5.1): an S at or above it is refused.
L = 2**252 + 27742317777372353535851937790883648493


@pytest.mark.parametrize("secret, public, message, signature", VECTORS)
def test_the_rfcs_own_vectors_verify(secret, public, message, signature):
    assert ed25519.verify(bytes.fromhex(public), bytes.fromhex(message), bytes.fromhex(signature))


@pytest.mark.parametrize("secret, public, message, signature", VECTORS)
def test_the_vectors_are_the_rfcs_and_not_a_mistake_copied_twice(secret, public, message, signature):
    """An independent implementation, from the secret key, makes the same public key and signature."""
    key = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(secret))
    made = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    assert made.hex() == public
    assert key.sign(bytes.fromhex(message)).hex() == signature


@pytest.mark.parametrize("secret, public, message, signature", VECTORS)
def test_one_bit_anywhere_is_a_no(secret, public, message, signature):
    public, message, signature = bytes.fromhex(public), bytes.fromhex(message), bytes.fromhex(signature)
    for index in (0, 31, 32, 63):
        changed = bytearray(signature)
        changed[index] ^= 0x01
        assert not ed25519.verify(public, message, bytes(changed)), f"signature byte {index}"
    if message:
        changed = bytearray(message)
        changed[len(changed) // 2] ^= 0x80
        assert not ed25519.verify(public, bytes(changed), signature)
    else:
        assert not ed25519.verify(public, b"\x00", signature)
    other = bytes.fromhex(VECTORS[1][1] if public != bytes.fromhex(VECTORS[1][1]) else VECTORS[0][1])
    assert not ed25519.verify(other, message, signature)


def test_an_s_at_or_above_the_group_order_is_refused_even_when_the_equation_would_hold():
    """RFC 8032, 5.1.7: S must be below L. S + L satisfies the same equation, so only this rule refuses it."""
    _, public, message, signature = (bytes.fromhex(part) for part in VECTORS[0])
    s = int.from_bytes(signature[32:], "little")
    malleated = signature[:32] + (s + L).to_bytes(32, "little")
    assert not ed25519.verify(public, message, malleated)


def test_what_is_not_a_key_or_a_signature_is_a_no_and_never_an_exception():
    _, public, message, signature = (bytes.fromhex(part) for part in VECTORS[0])
    assert not ed25519.verify(public[:31], message, signature)
    assert not ed25519.verify(public, message, signature[:63])
    assert not ed25519.verify(public + b"\x00", message, signature)
    # y = p is not a canonical encoding of any point.
    not_a_point = ((2**255 - 19).to_bytes(32, "little"))
    assert not ed25519.verify(not_a_point, message, signature)
    assert not ed25519.verify(public, message, not_a_point + signature[32:])


def test_it_agrees_with_an_independent_implementation_on_keys_it_never_saw():
    for size in (0, 1, 1000, 70_000):
        key = Ed25519PrivateKey.generate()
        public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        message = os.urandom(size)
        signature = key.sign(message)
        assert ed25519.verify(public, message, signature)
        assert not ed25519.verify(public, message + b"!", signature)
