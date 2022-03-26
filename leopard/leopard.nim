## Nim-Leopard
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises
push: {.upraises: [].}

{.deadCodeElim: on.}

import pkg/stew/results
import pkg/stew/byteutils

import ./wrapper
import ./utils

export wrapper, results

const
  BuffMultiples* = 64

type
  LeoBufferPtr* = ptr UncheckedArray[byte]

  LeoCoderKind* {.pure.} = enum
    Encoder,
    Decoder

  Leo* = object of RootObj
    bufSize*: int                       # size of the buffer in multiples of 64
    buffers*: int                       # total number of data buffers (K)
    parity*: int                        # total number of parity buffers (M)
    dataBufferPtr: seq[LeoBufferPtr]    # buffer where data is copied before encoding
    workBufferCount: int                # number of parity work buffers
    workBufferPtr: seq[LeoBufferPtr]    # buffer where parity is copied before encoding
    case kind: LeoCoderKind
    of LeoCoderKind.Decoder:
      decodeBufferCount: int              # number of decoding work buffers
      decodeBufferPtr: seq[LeoBufferPtr]  # work buffer used for decoding
    of LeoCoderKind.Encoder:
      discard

proc encode*(
  self: var Leo,
  data,
  parity: var openArray[seq[byte]]): Result[void, cstring] =
  ## Encode a list of buffers in `data` into a number of `bufSize` sized
  ## `parity` buffers
  ##
  ## `data`   - list of original data `buffers` of size `bufSize`
  ## `parity` - list of parity `buffers` of size `bufSize`
  ##

  # zero encode work buffer to avoid corrupting with previous run
  for i in 0..<self.workBufferCount:
    zeroMem(self.workBufferPtr[i], self.bufSize)

  # copy data into aligned buffer
  for i in 0..<data.len:
    copyMem(self.dataBufferPtr[i], addr data[i][0], self.bufSize)

  let
    res = leoEncode(
      self.bufSize.cuint,
      self.buffers.cuint,
      self.parity.cuint,
      self.workBufferCount.cuint,
      cast[ptr pointer](addr self.dataBufferPtr[0]),
      cast[ptr pointer](addr self.workBufferPtr[0]))

  if ord(res) != ord(LeopardSuccess):
    return err(leoResultString(res.LeopardResult))

  for i in 0..<parity.len:
    copyMem(addr parity[i][0], self.workBufferPtr[i], self.bufSize)

  return ok()

proc decode*(
  self: var Leo,
  data,
  parity,
  recovered: var openArray[seq[byte]]): Result[void, cstring] =
  ## Decode a list of buffers in `data` and `parity` into a list
  ## of `recovered` buffers of `bufSize`. The list of `recovered`
  ## buffers should be match the `Leo.buffers`
  ##
  ## `data`       - list of original data `buffers` of size `bufSize`
  ## `parity`     - list of parity `buffers` of size `bufSize`
  ## `recovered`  - list of recovered `buffers` of size `bufSize`
  ##

  if data.len != self.buffers: return err("Number of data buffers should match!")
  if parity.len != self.parity: return err("Number of parity buffers should match!")
  if recovered.len != self.buffers: return err("Number of recovered buffers should match buffers!")

  # zero both work buffers before decoding
  for i in 0..<self.workBufferCount:
    zeroMem(self.workBufferPtr[i], self.bufSize)

  for i in 0..<self.decodeBufferCount:
    zeroMem(self.decodeBufferPtr[i], self.bufSize)

  var
    dataPtr = newSeq[LeoBufferPtr](data.len)
    parityPtr = newSeq[LeoBufferPtr](self.workBufferCount)

  # copy data into aligned buffer
  for i in 0..<data.len:
    if data[i].len > 0:
      dataPtr[i] = self.dataBufferPtr[i]
      copyMem(self.dataBufferPtr[i], addr data[i][0], self.bufSize)
    else:
      dataPtr[i] = nil

  # copy parity into aligned buffer
  for i in 0..<self.workBufferCount:
    if i < parity.len and parity[i].len > 0:
      parityPtr[i] = self.workBufferPtr[i]
      copyMem(self.workBufferPtr[i], addr parity[i][0], self.bufSize)
    else:
      parityPtr[i] = nil

  let
    res = leo_decode(
      self.bufSize.cuint,
      self.buffers.cuint,
      self.parity.cuint,
      self.decodeBufferCount.cuint,
      cast[ptr pointer](addr dataPtr[0]),
      cast[ptr pointer](addr self.workBufferPtr[0]),
      cast[ptr pointer](addr self.decodeBufferPtr[0]))

  if ord(res) != ord(LeopardSuccess):
    return err(leoResultString(res.LeopardResult))

  for i in 0..<self.buffers:
    if data[i].len <= 0:
      copyMem(addr recovered[i][0], self.decodeBufferPtr[i], self.bufSize)

  ok()

proc free*(self: var Leo) =
  if self.workBufferPtr.len > 0:
    for i, p in self.workBufferPtr:
      p.leoFree()
      self.workBufferPtr[i] = nil

    self.workBufferPtr.setLen(0)

  if self.dataBufferPtr.len > 0:
    for i, p in self.dataBufferPtr:
      p.leoFree()
      self.dataBufferPtr[i] = nil

    self.dataBufferPtr.setLen(0)

  if self.kind == LeoCoderKind.Decoder:
    if self.decodeBufferPtr.len > 0:
      for i, p in self.decodeBufferPtr:
        p.leoFree()
        self.decodeBufferPtr[i] = nil
      self.decodeBufferPtr.setLen(0)

# TODO: The destructor doesn't behave as
# I'd expect it, it's called many more times
# than it should. This is however, most
# likely my misinterpretation of how it should
# work.
# proc `=destroy`*(self: var Leo) =
#   self.free()

proc setup*(self: var Leo, bufSize, buffers, parity: int): Result[void, cstring] =
  if bufSize mod BuffMultiples != 0:
    return err("bufSize should be multiples of 64 bytes!")

  once:
    # First attempt to init the library
    # This happens only once for all threads...
    if (let res = leoinit(); res.ord != LeopardSuccess.ord):
      return err(leoResultString(res.LeopardResult))

  self.bufSize = bufSize
  self.buffers = buffers
  self.parity = parity

  return ok()

proc init*(T: type Leo, bufSize, buffers, parity: int, kind: LeoCoderKind): Result[T, cstring] =
  if bufSize mod BuffMultiples != 0:
    return err("bufSize should be multiples of 64 bytes!")

  once:
    # First, attempt to init the library,
    # this happens only once for all threads and
    # should be safe as internal tables are only read,
    # never written. However instantiation should be
    # synchronized, since two instances can attempt to
    # concurrently instantiate the library twice, and
    # might end up with two distinct versions - not a big
    # deal but will defeat the purpose of this `once` block
    if (let res = leoinit(); res.ord != LeopardSuccess.ord):
      return err(leoResultString(res.LeopardResult))

  var
    self = Leo(
      kind: kind,
      bufSize: bufSize,
      buffers: buffers,
      parity: parity)

  self.workBufferCount = leoEncodeWorkCount(
    buffers.cuint,
    parity.cuint).int

  # initialize encode work buffers
  for _ in 0..<self.workBufferCount:
    self.workBufferPtr.add(cast[LeoBufferPtr](self.bufSize.leoAlloc()))

  # initialize data buffers
  for _ in 0..<self.buffers:
    self.dataBufferPtr.add(cast[LeoBufferPtr](self.bufSize.leoAlloc()))

  if self.kind == LeoCoderKind.Decoder:
    self.decodeBufferCount = leoDecodeWorkCount(
      buffers.cuint,
      parity.cuint).int

    # initialize decode work buffers
    for _ in 0..<self.decodeBufferCount:
      self.decodeBufferPtr.add(cast[LeoBufferPtr](self.bufSize.leoAlloc()))

  ok(self)