# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import asyncio
import random


async def sleep(i):
    await asyncio.sleep(i)

async def sleep_bad(i):
    asyncio.sleep(i)

async def call_sleep_ok():
    await sleep(1)


async def call_sleep_bad():
    sleep(1)

async def call_sleep_unknown_call_ok():
    unknown(sleep(1))


async def call_sleep_with_temp_ok():
    temp = sleep(1)
    await temp


async def call_sleep_with_branchs_ok(b):
    temp = sleep(1)
    if b:
        await temp
    else:
        await temp


async def call_sleep_with_branchs_bad1(b):
    temp = sleep(1)
    if b:
        await temp


async def call_sleep_with_branchs_bad2(b):
    temp = sleep(1)
    if b:
        return
    await temp

def main_ok():
    asyncio.run(sleep(10))

main_ok()

# no FP here
asyncio.run(sleep(10))
