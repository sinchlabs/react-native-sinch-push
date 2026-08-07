//
//  AVPlayerWrapperDelegate.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 26/10/2018.
//

import Foundation
import MediaPlayer

@MainActor
protocol AVPlayerWrapperDelegate: AnyObject {
    
    func AVWrapper(didChangeState state: AVPlayerWrapperState)
    func AVWrapper(secondsElapsed seconds: Double)
    func AVWrapper(failedWithError error: Error?)
    func AVWrapper(seekTo seconds: Int, didFinish: Bool)
    func AVWrapper(didUpdateDuration duration: Double)
    func AVWrapper(didReceiveMetadata metadata: [AVTimedMetadataGroup])
    func AVWrapperItemDidPlayToEndTime()
    func AVWrapperDidRecreateAVPlayer()
    
}
