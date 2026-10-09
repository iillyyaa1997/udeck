"""Ed25519 signatures checked as RFC 8032 checks them, with the standard library only.

Sparkle signs an update's archive with Ed25519 — `sparkle:edSignature` in the
appcast — and checks it against `SUPublicEDKey` in the application that is
running. A published release reaches the lab as two files from GitHub, its zip
and its appcast, and the lab checks one against the other, under the key the
zip's own Info.plist carries, before the zip goes anywhere near a guest
(`releases`). A zip that does not verify is one the lab cannot vouch for.

Verification only: the lab never signs with a release's key — the private half
lives in GitHub's secrets — and the keys it does sign with are its own, made and
used through Sparkle's `sign_update` (`builds`, `updates`).

This is the reference code of RFC 8032, section 6, kept as close to it as Python
allows: points in extended coordinates, the cofactorless check `[S]B = R + [k]A`,
and every rejection §5.1.7 asks for — a public key or an `R` that does not decode
to a point, and an `S` that is not below the group order. It is slow by the
standards of a C library and fast enough here: two scalar multiplications per
signature, and SHA-512 over the message, which is hashlib's. The lab's tests hold
it to the RFC's own test vectors.
"""

from __future__ import annotations

import hashlib

# The field, the curve's d, and the order of the base point (RFC 8032, 5.1).
_P = 2**255 - 19
_D = -121665 * pow(121666, _P - 2, _P) % _P
_L = 2**252 + 27742317777372353535851937790883648493
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)

Point = tuple[int, int, int, int]


def _add(a: Point, b: Point) -> Point:
    """Point addition in extended coordinates (RFC 8032, 6: point_add)."""
    first = (a[1] - a[0]) * (b[1] - b[0]) % _P
    second = (a[1] + a[0]) * (b[1] + b[0]) % _P
    third = 2 * a[3] * b[3] * _D % _P
    fourth = 2 * a[2] * b[2] % _P
    e, f, g, h = second - first, fourth - third, fourth + third, second + first
    return e * f % _P, g * h % _P, f * g % _P, e * h % _P


def _multiply(scalar: int, point: Point) -> Point:
    """Double and add (RFC 8032, 6: point_mul)."""
    result: Point = (0, 1, 1, 0)
    while scalar > 0:
        if scalar & 1:
            result = _add(result, point)
        point = _add(point, point)
        scalar >>= 1
    return result


def _equal(a: Point, b: Point) -> bool:
    """Whether two points in projective coordinates are the same point."""
    if (a[0] * b[2] - b[0] * a[2]) % _P != 0:
        return False
    return (a[1] * b[2] - b[1] * a[2]) % _P == 0


def _recover_x(y: int, sign: int) -> int | None:
    """The x of the point with this y and sign, or None when there is none (RFC 8032, 5.1.3)."""
    if y >= _P:
        return None
    x2 = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P) % _P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P != 0:
        x = x * _SQRT_M1 % _P
    if (x * x - x2) % _P != 0:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x


def _decompress(encoded: bytes) -> Point | None:
    if len(encoded) != 32:
        return None
    y = int.from_bytes(encoded, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return x, y, 1, x * y % _P


def _base_point() -> Point:
    y = 4 * pow(5, _P - 2, _P) % _P
    x = _recover_x(y, 0)
    if x is None:  # pragma: no cover — the curve's own base point always decodes
        raise ArithmeticError("the base point of edwards25519 did not decode")
    return x, y, 1, x * y % _P


_BASE = _base_point()


def verify(public_key: bytes, message: bytes, signature: bytes) -> bool:
    """Whether `signature` is `public_key`'s Ed25519 signature over `message` (RFC 8032, 5.1.7).

    False for anything malformed — a key or signature of the wrong length, a key
    or `R` that is not a point, an `S` at or above the group order — never an
    exception: the caller's question is yes or no.
    """
    if len(public_key) != 32 or len(signature) != 64:
        return False
    a = _decompress(public_key)
    if a is None:
        return False
    r = _decompress(signature[:32])
    if r is None:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= _L:
        return False
    k = int.from_bytes(hashlib.sha512(signature[:32] + public_key + message).digest(), "little") % _L
    return _equal(_multiply(s, _BASE), _add(r, _multiply(k, a)))
