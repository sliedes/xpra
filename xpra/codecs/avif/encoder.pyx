# This file is part of Xpra.
# Copyright (C) 2022 Antoine Martin <antoine@xpra.org>
# Xpra is released under the terms of the GNU GPL v2, or, at your option, any
# later version. See the file COPYING for details.

import os

from libc.stdint cimport uint8_t, uint32_t, uint64_t, uintptr_t   #pylint: disable=syntax-error
from libc.string cimport memset #pylint: disable=syntax-error
from xpra.buffers.membuf cimport buffer_context
from xpra.codecs.avif.avif cimport (
    AVIF_RESULT_OK,
    AVIF_VERSION_MAJOR, AVIF_VERSION_MINOR, AVIF_VERSION_PATCH,
    AVIF_RESULT,
    avifResult,
    avifRWData,
    AVIF_PIXEL_FORMAT_YUV444,
    avifImage, avifRGBImage, avifImageCreate, avifImageDestroy,
    AVIF_RGB_FORMAT_BGRA,
    avifRGBFormat,
    AVIF_CHROMA_UPSAMPLING_FASTEST,
    avifChromaUpsampling,
    AVIF_ADD_IMAGE_FLAG_SINGLE,
    avifAddImageFlags,
    avifEncoder, avifEncoderCreate, avifEncoderAddImage, avifEncoderWrite, avifEncoderFinish, avifEncoderDestroy,
    avifRWDataFree,
    avifImageRGBToYUV,
    avifRGBImageSetDefaults,
    avifResultToString,
    )

from xpra.util import envint
from xpra.net.compression import Compressed
from xpra.codecs.codec_debug import may_save_image
from xpra.log import Logger
log = Logger("encoder", "avif")

THREADS = envint("XPRA_AVIF_THREADS", min(4, max(1, os.cpu_count()//2)))
DEF AVIF_PLANE_COUNT_YUV = 3


def get_type():
    return "avif"

def get_encodings():
    return ("avif", )

def get_version():
    return (AVIF_VERSION_MAJOR, AVIF_VERSION_MINOR, AVIF_VERSION_PATCH)

def get_info():
    return  {
            "version"       : get_version(),
            "encodings"     : get_encodings(),
            }

def init_module():
    log("avif.init_module()")

def cleanup_module():
    log("avif.cleanup_module()")


INPUT_PIXEL_FORMATS = ("RGBX", "RGBA", "BGRX", "BGRA", "RGB", "BGR")

cdef check(avifResult r, message):
    if r != AVIF_RESULT_OK:
        err = avifResultToString(r) or AVIF_RESULT.get(r, r)
        raise Exception("%s : %s" % (message, err))

def encode(coding, image, options=None):
    pixel_format = image.get_pixel_format()
    pixels = image.get_pixels()
    cdef int width = image.get_width()
    cdef int height = image.get_height()
    cdef avifImage *avif_image = avifImageCreate(width, height, 8, AVIF_PIXEL_FORMAT_YUV444)
    if avif_image==NULL:
        raise Exception("failed to allocate avif image")
    cdef avifRGBImage rgb
    memset(&rgb, 0, sizeof(avifRGBImage))

    avifRGBImageSetDefaults(&rgb, avif_image)
    rgb.format = AVIF_RGB_FORMAT_BGRA
    rgb.chromaUpsampling = AVIF_CHROMA_UPSAMPLING_FASTEST
    rgb.ignoreAlpha = pixel_format.find("A")<0
    rgb.alphaPremultiplied = 1
    rgb.rowBytes = image.get_rowstride()

    cdef avifResult r
    cdef avifEncoder * encoder = NULL
    cdef avifRWData avifOutput
    memset(&avifOutput, 0, sizeof(avifRWData))

    with buffer_context(pixels) as bc:
        rgb.pixels = <uint8_t*> (<uintptr_t> int(bc))
        log("avif.encode(%s, %s, %s) pixels=%#x", coding, image, options, int(bc))

        try:
            r = avifImageRGBToYUV(avif_image, &rgb)
            log("avifImageRGBToYUV()=%i", r)
            check(r, "Failed to convert to YUV(A)")
    
            encoder = avifEncoderCreate()
            log("avifEncoderCreate()=%#x", <uintptr_t> encoder)
            if encoder==NULL:
                raise Exception("failed to create avif encoder")
            # Configure your encoder here (see avif/avif.h):
            encoder.speed = 10
            encoder.maxThreads = THREADS
            # * maxThreads
            # * minQuantizer
            # * maxQuantizer
            # * minQuantizerAlpha
            # * maxQuantizerAlpha
            # * tileRowsLog2
            # * tileColsLog2
            # * speed
            # * keyframeInterval
            # * timescale
            r = avifEncoderAddImage(encoder, avif_image, 1, AVIF_ADD_IMAGE_FLAG_SINGLE)
            log("avifEncoderAddImage()=%i", r)
            check(r, "Failed to add image to encoder")
    
            r = avifEncoderFinish(encoder, &avifOutput)
            log("avifEncoderFinish()=%i", r)
            check(r, "Failed to finish encode")
    
            client_options = {"alpha" : pixel_format.find("A")>=0}
            cdata = avifOutput.data[:avifOutput.size]
            log("avif: got %i bytes", avifOutput.size)
            may_save_image("avif", cdata)
            return "avif", Compressed("avif", cdata), client_options, width, height, 0, len(pixel_format.replace("A", ""))*8
        finally:
            avifImageDestroy(avif_image)
            if encoder:
                avifEncoderDestroy(encoder)
            avifRWDataFree(&avifOutput)


def selftest(full=False):
    #fake empty buffer:
    from xpra.codecs.codec_checks import make_test_image
    w, h = 24, 16
    for has_alpha in (True, False):
        img = make_test_image("BGR%s" % ["X", "A"][has_alpha], w, h)
        for q in (10, 50, 90):
            r = encode("webp", img, {"quality" : q, "speed" : 50, "alpha" : has_alpha})
            assert len(r)>0
