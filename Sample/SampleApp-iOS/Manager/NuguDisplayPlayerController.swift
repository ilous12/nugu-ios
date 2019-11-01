//
//  NuguDisplayPlayerController.swift
//  SampleApp-iOS
//
//  Created by yonghoonKwon on 02/08/2019.
//  Copyright (c) 2019 SK Telecom Co., Ltd. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import MediaPlayer

import NuguInterface
import NuguClientKit

// NuguClient에서 처리할 수 있을지 검토예정
final class NuguDisplayPlayerController {
    
    // MARK: Properties
    
    private let client: NuguClient
    
    private var playCommandTarget: Any?
    private var pauseCommandTarget: Any?
    private var previousCommandTarget: Any?
    private var nextCommandTarget: Any?
    private var seekCommandTarget: Any?
    
    private var currentItem: AudioPlayerDisplayTemplate?
    private var currentState: AudioPlayerState = .idle
    
    // MARK: Initialize
    
    init(client: NuguClient) {
        self.client = client
    }
    
    func use() {
        client.audioPlayerAgent?.add(displayDelegate: self)
        client.audioPlayerAgent?.add(delegate: self)
    }
    
    func unuse() {
        client.audioPlayerAgent?.remove(displayDelegate: self)
        client.audioPlayerAgent?.remove(delegate: self)
    }
}

// MARK: - MPNowPlayingInfoCenter

private extension NuguDisplayPlayerController {
    func addRemoteCommands() {
        addPlayCommand()
        addPauseCommand()
        addPreviousTrackCommand()
        addNextTackCommand()
        addChangePlaybackPositionCommand()
    }
    
    func removeRemoteCommands() {
        removePlayCommand()
        removePauseCommand()
        removePreviousTrackCommand()
        removeNextTrackCommand()
        removeChangePlaybackPositionCommand()
    }
    
    func remove() {
        currentItem = nil
        
        update()
    }
    
    func update(
        newItem: AudioPlayerDisplayTemplate? = nil,
        newState: AudioPlayerState? = nil
        ) {
        let item = newItem ?? currentItem
        let state = newState ?? currentState
        
        defer {
            currentItem = item
            currentState = state
        }
        
        guard let playerItem = currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            removeRemoteCommands()
            return
        }
        
        let duration: Int
        let title: String
        let albumTitle: String
        let imageUrl: String?
        
        switch playerItem.typeInfo {
        case .audioPlayer(let item):
            duration = client.audioPlayerAgent?.duration ?? 0
            title = item.template.title.text
            albumTitle = item.template.content.title
            imageUrl = item.template.content.imageUrl
        }
        
        // Set nowPlayingInfo display properties
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = albumTitle
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPMediaItemPropertyArtwork] = nil
    
        let offset = client.audioPlayerAgent?.offset ?? 0
        switch state {
        case .playing:
            addRemoteCommands()
            // Set playbackTime as current offset, set playbackRate as 1
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = offset
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        case .paused:
            // Set playbackRate as 0, set playbackTime as current offset
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = offset
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        default:
            // Set playbackRate as 0, set playbackTime as 0
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        }
        
        
        // Set MPMediaItemArtwork if imageUrl exists
        if let imageUrl = imageUrl, let artWorkUrl = URL(string: imageUrl) {
            ImageDataLoader.shared.load(imageUrl: artWorkUrl) { (result) in
                switch result {
                case .success(let imageData):
                    guard let artWorkImage = UIImage(data: imageData) else { return }
                    let artWork = MPMediaItemArtwork(boundsSize: artWorkImage.size, requestHandler: { _ -> UIImage in
                        return artWorkImage
                    })
                    
                    nowPlayingInfo[MPMediaItemPropertyArtwork] = artWork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                case .failure:
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                }
            }
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }
}

// MARK: - Private (MPRemoteCommandCenter.Command)

private extension NuguDisplayPlayerController {
    
    // MARK: Add Commands
    
    func addPlayCommand() {
        guard playCommandTarget == nil else { return }
        
        if playCommandTarget == nil {
            playCommandTarget = MPRemoteCommandCenter.shared()
                .playCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
                    self?.client.audioPlayerAgent?.play()
                    return .success
            }
        }
    }
    
    func addPauseCommand() {
        guard pauseCommandTarget == nil else { return }
        
        pauseCommandTarget = MPRemoteCommandCenter.shared()
            .pauseCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
                self?.client.audioPlayerAgent?.pause()
                return .success
        }
    }
    
    func addPreviousTrackCommand() {
        guard previousCommandTarget == nil else { return }
        
        previousCommandTarget = MPRemoteCommandCenter.shared()
            .previousTrackCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
                self?.client.audioPlayerAgent?.prev()
                return .success
        }
    }
    
    func addNextTackCommand() {
        guard nextCommandTarget == nil else { return }
        
        nextCommandTarget = MPRemoteCommandCenter.shared()
            .nextTrackCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
                self?.client.audioPlayerAgent?.next()
                return .success
        }
    }
    
    func addChangePlaybackPositionCommand() {
        guard seekCommandTarget == nil else { return }
        
        seekCommandTarget = MPRemoteCommandCenter.shared()
            .changePlaybackPositionCommand.addTarget { [weak self] (event) -> MPRemoteCommandHandlerStatus in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                self?.client.audioPlayerAgent?.seek(to: Int(event.positionTime))
                return .success
        }
    }
    
    // MARK: Remove Commands
    
    func removePlayCommand() {
        MPRemoteCommandCenter.shared().playCommand.removeTarget(playCommandTarget)
        playCommandTarget = nil
    }
    
    func removePauseCommand() {
        MPRemoteCommandCenter.shared().pauseCommand.removeTarget(pauseCommandTarget)
        pauseCommandTarget = nil
    }
    
    func removePreviousTrackCommand() {
        MPRemoteCommandCenter.shared().previousTrackCommand.removeTarget(previousCommandTarget)
        previousCommandTarget = nil
    }
    
    func removeNextTrackCommand() {
        MPRemoteCommandCenter.shared().nextTrackCommand.removeTarget(nextCommandTarget)
        nextCommandTarget = nil
    }
    
    func removeChangePlaybackPositionCommand() {
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.removeTarget(seekCommandTarget)
        seekCommandTarget = nil
    }
}


// MARK: - DisplayPlayerAgentDelegate

extension NuguDisplayPlayerController: AudioPlayerDisplayDelegate {
    func audioPlayerDisplayShouldRender(template: AudioPlayerDisplayTemplate) -> Bool {
        return true
    }
    
    func audioPlayerDisplayDidRender(template: AudioPlayerDisplayTemplate) {
        DispatchQueue.main.async { [weak self] in
            self?.update(newItem: template)
        }
    }
    
    func audioPlayerDisplayShouldClear(template: AudioPlayerDisplayTemplate) -> Bool {
        return true
    }
    
    func audioPlayerDisplayDidClear(template: AudioPlayerDisplayTemplate) {
        DispatchQueue.main.async { [weak self] in
            self?.remove()
        }
    }
}

// MARK: - AudioPlayerAgentDelegate

extension NuguDisplayPlayerController: AudioPlayerAgentDelegate {
    func audioPlayerAgentDidChange(state: AudioPlayerState) {
        DispatchQueue.main.async { [weak self] in
            self?.update(newState: state)
        }
    }
}