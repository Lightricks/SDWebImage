/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#ifdef SD_WEBP

#import "UIImage+WebP.h"
#import "webp/decode.h"
#import "webp/mux_types.h"
#import "webp/demux.h"
#import "NSImage+WebCache.h"

// Callback for CGDataProviderRelease
static void FreeImageData(void *info, const void *data, size_t size) {
    free((void *)data);
}

@implementation UIImage (WebP)

+ (nullable UIImage *)sd_imageWithWebPData:(nullable NSData *)data {
    if (!data) {
        return nil;
    }
    
    WebPData webpData;
    WebPDataInit(&webpData);
    webpData.bytes = data.bytes;
    webpData.size = data.length;
    WebPDemuxer *demuxer = WebPDemux(&webpData);
    if (!demuxer) {
        return nil;
    }
    
    uint32_t flags = WebPDemuxGetI(demuxer, WEBP_FF_FORMAT_FLAGS);
    if (!(flags & ANIMATION_FLAG)) {
        // for static single webp image
        UIImage *staticImage = [self sd_rawWebpImageWithData:webpData];
        WebPDemuxDelete(demuxer);
        return staticImage;
    }
    
    WebPIterator iter;
    if (!WebPDemuxGetFrame(demuxer, 1, &iter)) {
        WebPDemuxReleaseIterator(&iter);
        WebPDemuxDelete(demuxer);
        return nil;
    }
    
    NSMutableArray *images = [NSMutableArray array];
    NSTimeInterval duration = 0;
    
    int canvasWidth = WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_WIDTH);
    int canvasHeight = WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_HEIGHT);
    CGContextRef canvas = CGBitmapContextCreate(NULL, canvasWidth, canvasHeight, 8, 0, sd_CGColorSpaceGetDeviceRGB(), kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    
    do {
        UIImage *image;
        if (iter.blend_method == WEBP_MUX_BLEND) {
            image = [self sd_blendWebpImageWithCanvas:canvas iterator:iter];
        } else {
            image = [self sd_nonblendWebpImageWithCanvas:canvas iterator:iter];
        }
        
        if (!image) {
            continue;
        }
        
        [images addObject:image];
        duration += iter.duration / 1000.0f;
        
    } while (WebPDemuxNextFrame(&iter));
    
    WebPDemuxReleaseIterator(&iter);
    WebPDemuxDelete(demuxer);
    CGContextRelease(canvas);
    
    UIImage *finalImage = nil;
#if SD_UIKIT || SD_WATCH
    finalImage = [UIImage animatedImageWithImages:images duration:duration];
#elif SD_MAC
    if ([images count] > 0) {
        finalImage = images[0];
    }
#endif
    return finalImage;
}


+ (nullable UIImage *)sd_blendWebpImageWithCanvas:(CGContextRef)canvas iterator:(WebPIterator)iter {
    UIImage *image = [self sd_rawWebpImageWithData:iter.fragment];
    if (!image) {
        return nil;
    }
    
    size_t canvasWidth = CGBitmapContextGetWidth(canvas);
    size_t canvasHeight = CGBitmapContextGetHeight(canvas);
    CGSize size = CGSizeMake(canvasWidth, canvasHeight);
    CGFloat tmpX = iter.x_offset;
    CGFloat tmpY = size.height - iter.height - iter.y_offset;
    CGRect imageRect = CGRectMake(tmpX, tmpY, iter.width, iter.height);
    
    CGContextDrawImage(canvas, imageRect, image.CGImage);
    CGImageRef newImageRef = CGBitmapContextCreateImage(canvas);
    
#if SD_UIKIT || SD_WATCH
    image = [UIImage imageWithCGImage:newImageRef];
#elif SD_MAC
    image = [[UIImage alloc] initWithCGImage:newImageRef size:NSZeroSize];
#endif
    
    CGImageRelease(newImageRef);
    
    if (iter.dispose_method == WEBP_MUX_DISPOSE_NONE) {
        // do not dispose
    } else {
        CGContextClearRect(canvas, imageRect);
    }
    
    return image;
}

+ (nullable UIImage *)sd_nonblendWebpImageWithCanvas:(CGContextRef)canvas iterator:(WebPIterator)iter {
    UIImage *image = [self sd_rawWebpImageWithData:iter.fragment];
    if (!image) {
        return nil;
    }
    
    size_t canvasWidth = CGBitmapContextGetWidth(canvas);
    size_t canvasHeight = CGBitmapContextGetHeight(canvas);
    CGSize size = CGSizeMake(canvasWidth, canvasHeight);
    CGFloat tmpX = iter.x_offset;
    CGFloat tmpY = size.height - iter.height - iter.y_offset;
    CGRect imageRect = CGRectMake(tmpX, tmpY, iter.width, iter.height);
    
    CGContextClearRect(canvas, imageRect);
    CGContextDrawImage(canvas, imageRect, image.CGImage);
    CGImageRef newImageRef = CGBitmapContextCreateImage(canvas);
    
#if SD_UIKIT || SD_WATCH
    image = [UIImage imageWithCGImage:newImageRef];
#elif SD_MAC
    image = [[UIImage alloc] initWithCGImage:newImageRef size:NSZeroSize];
#endif
    
    CGImageRelease(newImageRef);
    
    if (iter.dispose_method == WEBP_MUX_DISPOSE_NONE) {
        // do not dispose
    } else {
        CGContextClearRect(canvas, imageRect);
    }
    
    return image;
}

+ (nullable UIImage *)sd_rawWebpImageWithData:(WebPData)webpData {
    WebPDecoderConfig config;
    if (!WebPInitDecoderConfig(&config)) {
        return nil;
    }

    if (WebPGetFeatures(webpData.bytes, webpData.size, &config.input) != VP8_STATUS_OK) {
        return nil;
    }

    config.output.colorspace = config.input.has_alpha ? MODE_rgbA : MODE_RGB;
    config.options.use_threads = 1;

    // Decode the WebP image data into a RGBA value array.
    if (WebPDecode(webpData.bytes, webpData.size, &config) != VP8_STATUS_OK) {
        return nil;
    }

    int width = config.input.width;
    int height = config.input.height;
    if (config.options.use_scaling) {
        width = config.options.scaled_width;
        height = config.options.scaled_height;
    }

    // Construct a UIImage from the decoded RGBA value array.
    CGDataProviderRef provider =
    CGDataProviderCreateWithData(NULL, config.output.u.RGBA.rgba, config.output.u.RGBA.size, FreeImageData);
    CGColorSpaceRef colorSpaceRef = sd_CGColorSpaceGetDeviceRGB();
    CGBitmapInfo bitmapInfo = config.input.has_alpha ? kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast : kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast;
    size_t components = config.input.has_alpha ? 4 : 3;
    CGColorRenderingIntent renderingIntent = kCGRenderingIntentDefault;
    CGImageRef imageRef = CGImageCreate(width, height, 8, components * 8, components * width, colorSpaceRef, bitmapInfo, provider, NULL, NO, renderingIntent);

    CGDataProviderRelease(provider);

#if SD_UIKIT || SD_WATCH
    UIImage *image = [[UIImage alloc] initWithCGImage:imageRef];
#else
    UIImage *image = [[UIImage alloc] initWithCGImage:imageRef size:NSZeroSize];
#endif
    CGImageRelease(imageRef);

    return image;
}

static CGColorSpaceRef sd_CGColorSpaceGetDeviceRGB() {
    static CGColorSpaceRef space;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        space = CGColorSpaceCreateDeviceRGB();
    });
    return space;
}

@end

#endif
