//
//  SoundAgent.swift
//  NuguAgents
//
//  Created by MinChul Lee on 2020/04/07.
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

import NuguCore

public final class SoundAgent: SoundAgentProtocol {
    // CapabilityAgentable
    public var capabilityAgentProperty: CapabilityAgentProperty = CapabilityAgentProperty(category: .sound, version: "1.0")
    
    // SoundAgentProtocol
    public weak var dataSource: SoundAgentDataSource?
    public weak var delegate: SoundAgentDelegate?
    public var volume: Float = 1.0 {
        didSet {
            currentPlayer?.volume = volume
        }
    }
    
    // Private
    private let contextManager: ContextManageable
    private let focusManager: FocusManageable
    private let directiveSequencer: DirectiveSequenceable
    private let upstreamDataSender: UpstreamDataSendable
    
    private let soundDispatchQueue = DispatchQueue(label: "com.sktelecom.romaine.sound_agent", qos: .userInitiated)
    
    private var soundState: SoundState = .idle {
        didSet {
            log.info("state changed from: \(oldValue) to: \(soundState)")
            guard let media = currentMedia else {
                log.error("TTSMedia is nil")
                return
            }
            
            // Release focus
            switch soundState {
            case .idle, .finished, .stopped:
                releaseFocusIfNeeded()
            case .playing:
                break
            }
            
            // Notify delegates only if the agent's status changes.
            if oldValue != soundState {
                delegate?.soundAgentDidChange(state: soundState, dialogRequestId: media.dialogRequestId)
            }
        }
    }
    private var currentMedia: SoundMedia?
    private var currentPlayer: MediaPlayable?
    
    // Handleable Directives
    private lazy var handleableDirectiveInfos = [
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "Beep", blockingPolicy: BlockingPolicy(medium: .audio, isBlocking: true), preFetch: prefetchBeep, directiveHandler: handleBeep)
    ]
    
    public init(
        focusManager: FocusManageable,
        upstreamDataSender: UpstreamDataSendable,
        contextManager: ContextManageable,
        directiveSequencer: DirectiveSequenceable
    ) {
        self.focusManager = focusManager
        self.upstreamDataSender = upstreamDataSender
        self.contextManager = contextManager
        self.directiveSequencer = directiveSequencer
        
        contextManager.add(delegate: self)
        focusManager.add(channelDelegate: self)
        directiveSequencer.add(directiveHandleInfos: handleableDirectiveInfos.asDictionary)
    }
    
    deinit {
        directiveSequencer.remove(directiveHandleInfos: handleableDirectiveInfos.asDictionary)
        currentPlayer?.stop()
    }
}

// MARK: - FocusChannelDelegate

extension SoundAgent: FocusChannelDelegate {
    public func focusChannelPriority() -> FocusChannelPriority {
        return .sound
    }
    
    public func focusChannelDidChange(focusState: FocusState) {
        soundDispatchQueue.sync { [weak self] in
            guard let self = self else { return }

            log.info("\(focusState) \(self.soundState)")
            switch (focusState, self.soundState) {
            case (.foreground, let soundState) where [.idle, .stopped, .finished].contains(soundState):
                self.currentPlayer?.play()
            // Foreground. playing 무시
            case (.foreground, _):
                break
            case (.background, .playing):
                self.stop()
            // background. idle, stopped, finished 무시
            case (.background, _):
                break
            case (.nothing, .playing):
                self.stop()
            // none. idle/stopped/finished 무시
            case (.nothing, _):
                break
            }
        }
    }
}

// MARK: - ContextInfoDelegate

extension SoundAgent: ContextInfoDelegate {
    public func contextInfoRequestContext(completion: (ContextInfo?) -> Void) {
        let payload: [String: AnyHashable] = ["version": capabilityAgentProperty.version]
        completion(ContextInfo(contextType: .capability, name: capabilityAgentProperty.name, payload: payload))
    }
}

// MARK: - MediaPlayerDelegate

extension SoundAgent: MediaPlayerDelegate {
    public func mediaPlayerDidChange(state: MediaPlayerState) {
        log.info("media state: \(state)")
        
        soundDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            // `SoundState` -> `FocusState`
            switch state {
            case .start, .resume:
                self.soundState = .playing
            case .finish:
                self.soundState = .finished
            case .pause:
                self.stop()
            case .stop:
                self.soundState = .stopped
            case .bufferUnderrun, .bufferRefilled:
                break
            case .error:
                self.soundState = .stopped
            }
        }
    }
}

// MARK: - Private (Directive)

private extension SoundAgent {
    func prefetchBeep() -> PrefetchDirective {
        return { [weak self] directive in
            guard let self = self else { return }
            let payload = try JSONDecoder().decode(SoundMedia.Payload.self, from: directive.payload)
            
            self.soundDispatchQueue.async { [weak self] in
                guard let self = self else { return }
                guard let url = self.dataSource?.soundAgentRequestUrl(beepName: payload.beepName, dialogRequestId: directive.header.dialogRequestId) else {
                    self.sendEvent(
                        playServiceId: payload.playServiceId,
                        referrerDialogRequestId: directive.header.dialogRequestId,
                        info: .beepFailed
                    )
                    return
                }
                self.stopSilently()
                
                let mediaPlayer = MediaPlayer()
                mediaPlayer.setSource(url: url)
                mediaPlayer.delegate = self
                mediaPlayer.volume = self.volume
                
                self.currentPlayer = mediaPlayer
                self.currentMedia = SoundMedia(
                    payload: payload,
                    dialogRequestId: directive.header.dialogRequestId,
                    messageId: directive.header.messageId
                )
                self.sendEvent(
                    playServiceId: payload.playServiceId,
                    referrerDialogRequestId: directive.header.dialogRequestId,
                    info: .beepSucceeded
                )
            }
        }
    }
    
    func handleBeep() -> HandleDirective {
        return { [weak self] directive, completion in
            defer { completion(.finished) }
            
            self?.soundDispatchQueue.async { [weak self] in
                guard let self = self else { return }
                guard self.currentMedia?.messageId == directive.header.messageId else {
                    log.info("Message id does not match")
                    return
                }
                
                self.focusManager.requestFocus(channelDelegate: self)
            }
        }
    }
}

// MARK: - Private (MediaPlayer)

private extension SoundAgent {
    func stop() {
        soundDispatchQueue.precondition(.onQueue)
        currentPlayer?.stop()
    }
    
    /// Synchronously stop previously playing beep
    func stopSilently() {
        soundDispatchQueue.precondition(.onQueue)
        guard let player = currentPlayer else { return }
        
        // `MediaPlayer` -> `SoundState`
        player.delegate = nil
        player.stop()
        soundState = .stopped
    }
}

// MARK: - Private (Event)

private extension SoundAgent {
    func sendEvent(playServiceId: String, referrerDialogRequestId: String, info: Event.TypeInfo) {
        let eventIdentifier = EventIdentifier()
        contextManager.getContexts(namespace: capabilityAgentProperty.name) { [weak self] contextPayload in
            guard let self = self else { return }
            
            self.upstreamDataSender.sendEvent(
                Event(
                    playServiceId: playServiceId,
                    typeInfo: info
                ).makeEventMessage(
                    property: self.capabilityAgentProperty,
                    eventIdentifier: eventIdentifier,
                    referrerDialogRequestId: referrerDialogRequestId,
                    contextPayload: contextPayload
                )
            )
        }
    }
}

// MARK: - Private(FocusManager)

private extension SoundAgent {
    func releaseFocusIfNeeded() {
        guard [.idle, .stopped, .finished].contains(soundState) else {
            log.info("Not permitted in current state, \(soundState)")
            return
        }
        focusManager.releaseFocus(channelDelegate: self)
    }
}
