//
//  main.swift
//  tutorial6
//
//  Created by Kwanghoon Choi on 2016. 9. 4..
//  Copyright © 2016년 gretech. All rights reserved.
//

import Foundation
import AVFoundation
import CoreAudio
import Accelerate
import AppKit

var path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/sample.mp4")

struct VideoData {
    let y: Data
    let u: Data
    let v: Data
    
    let lumaLength: Int32
    let chromaLength: Int32
    
    let w: Int32
    let h: Int32
    
    let pts: Int64
    let dur: Int64
    var end: Int64 {
        return dur + pts == Int64.min ? 0 : pts
    }
    let time_base: AVRational
    var time: Double {
        if pts == Int64.min {
            return 0
        }
        return Double(pts) * av_q2d(time_base)
    }
    var timeRange: Range<Double> {
        return time..<(Double(end) * av_q2d(time_base))
    }
}

class Player {
    
    var playLock: DispatchSemaphore = DispatchSemaphore(value: 0)
    var stopHandle: () -> Void
    
    var window: OpaquePointer?
    var wr: SDL_Rect = SDL_Rect()
    var renderer: OpaquePointer?
    var texture: OpaquePointer?
    
    init(stopHandle: @escaping () -> Void) {
        self.stopHandle = stopHandle
    }
    
    func start() {
        SDL_SetMainReady()
        
        guard 0 <= SDL_Init(Uint32(SDL_INIT_VIDEO)) else {
            return
        }
        guard let screen = NSScreen.screens()?.first?.frame.applying(CGAffineTransform(scaleX: 0.5, y: 0.5)) else {
            return
        }
        wr.x = Int32(screen.origin.x)
        wr.y = Int32(screen.origin.y)
        wr.w = Int32(screen.width)
        wr.h = Int32(screen.height)
        let flags = SDL_WINDOW_OPENGL.rawValue | SDL_WINDOW_BORDERLESS.rawValue
        guard let w = SDL_CreateWindow("tutorial6", wr.x, wr.y, wr.w, wr.h, flags) else {
            return
        }
        window = w
        guard let r = SDL_CreateRenderer(w, -1, SDL_RENDERER_ACCELERATED.rawValue | SDL_RENDERER_TARGETTEXTURE.rawValue) else {
            return
        }
        renderer = r
        
        SDL_ShowWindow(window)
        
        av_register_all()
        avfilter_register_all()
        avformat_network_init()
        
        decode()
    }
    
    func stop() {
        avformat_network_deinit()
        self.stopHandle()
        self.playLock.signal()
    }
    
    var format: UnsafeMutablePointer<AVFormatContext>?
    let decodeQueue: DispatchQueue = DispatchQueue(label: "decode")
    let decodeLock: DispatchSemaphore = DispatchSemaphore(value: 1)
    var videoStream: SweetStream!
    var videoRect: SDL_Rect = SDL_Rect()
    func decode() {
        guard 0 <= avformat_open_input(&format, path.path, nil, nil) else {
            self.stop()
            return
        }
        
        guard 0 <= avformat_find_stream_info(format, nil) else {
            self.stop()
            return
        }
        
        av_dump_format(format, -1, path.path, 0)
        
        guard let videoStream = SweetStream(format: format, type: AVMEDIA_TYPE_VIDEO) else {
            return
        }
        self.videoStream = videoStream
        guard videoStream.open() else {
            return
        }
        
        videoRect.w = videoStream.w
        videoRect.h = videoStream.h
        texture = SDL_CreateTexture(renderer, Uint32(SDL_PIXELFORMAT_IYUV), Int32(SDL_TEXTUREACCESS_STREAMING.rawValue), videoRect.w, videoRect.h)
        
        let videoIndex = self.videoStream.index
        let time_base = self.videoStream.time_base
        decodeQueue.async {
            
            self.startDisplay(fps: self.videoStream.fps)
            
            var ret: Int32 = 0
            var pkt = av_packet_alloc()
            var frame = av_frame_alloc()
            defer {
                av_packet_unref(pkt)
                av_frame_unref(frame)
                av_packet_free(&pkt)
                av_frame_free(&frame)
            }
            while true {
                ret = av_read_frame(self.format, pkt)
                guard 0 <= ret else {
                    break
                }
                switch pkt?.pointee.stream_index {
                case videoIndex?:
                    ret = avcodec_send_packet(self.videoStream.codec, pkt)
                    if 0 > ret && ret != AVERROR_CONVERT(EAGAIN) && false == IS_AVERROR_EOF(ret) {
                        break
                    }
                    ret = avcodec_receive_frame(self.videoStream.codec, frame)
                    if ret == AVERROR_CONVERT(EAGAIN) || IS_AVERROR_EOF(ret) {
                        continue
                    } else if 0 > ret {
                        break
                    }
                    guard let data = frame?.pointee.videoData(time_base: time_base) else {
                        continue
                    }
                    self.decodeLock.wait()
                    self.displayLock.wait()
                    self.videoQueue.insert(data, at: 0)
                    self.displayLock.signal()
                    if 12 > self.videoQueue.count {
                        self.decodeLock.signal()
                    }
                default:
                    break
                }
            }
        }
    }
    
    var videoQueue: [VideoData] = []
    var displayLock: DispatchSemaphore = DispatchSemaphore(value: 1)
    let displayQueue = DispatchQueue(label: "timer", attributes: .concurrent)
    lazy var timer: DispatchSourceTimer? = DispatchSource.makeTimerSource(flags: .strict, queue:self.displayQueue)
    
    func startDisplay(fps: Double) {
        timer?.scheduleRepeating(deadline: .now(), interval: fps, leeway: DispatchTimeInterval.nanoseconds(0))
        timer?.setEventHandler {
            self.displayLock.wait()
            if let data = self.videoQueue.popLast() {
                var tr = CGRect(x: 0, y: 0, width: Int(data.w), height: Int(data.h))
                var ww: Int32 = 0
                var wh: Int32 = 0
                SDL_GetWindowSize(self.window, &ww, &wh)
                tr = AVMakeRect(aspectRatio: CGSize(width: Int(data.w), height: Int(data.h)), insideRect: CGRect(x: 0, y: 0, width: CGFloat(ww), height: CGFloat(ww)))
                var dstrect = SDL_Rect(
                    x: Int32(0),
                    y: Int32(0),
                    w: Int32(tr.width),
                    h: Int32(tr.height))
                var src =  SDL_Rect(x: 0, y: 0, w: data.w, h: data.h)
                let y: UnsafePointer<UInt8> = data.y.withUnsafeBytes(){$0}
                let u: UnsafePointer<Uint8> = data.u.withUnsafeBytes(){$0}
                let v: UnsafePointer<Uint8> = data.v.withUnsafeBytes(){$0}
                SDL_UpdateYUVTexture(self.texture, &self.videoRect, y, data.lumaLength, u, data.chromaLength, v, data.chromaLength)
                SDL_RenderClear(self.renderer)
                SDL_RenderCopy(self.renderer, self.texture, &src, &dstrect)
                SDL_RenderPresent(self.renderer)
                print(data.timeRange)
            }
            self.displayLock.signal()
            self.decodeLock.signal()
        }
        timer?.resume()
    }
}

let player = Player { 
    
}
DispatchQueue.global().async {
    player.start()
}
player.playLock.wait()
