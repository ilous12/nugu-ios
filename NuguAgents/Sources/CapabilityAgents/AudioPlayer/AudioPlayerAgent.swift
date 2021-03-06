//
//  AudioPlayerAgent.swift
//  NuguAgents
//
//  Created by MinChul Lee on 11/04/2019.
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
import SilverTray

import RxSwift

public final class AudioPlayerAgent: AudioPlayerAgentProtocol {
    // CapabilityAgentable
    public var capabilityAgentProperty: CapabilityAgentProperty = CapabilityAgentProperty(category: .audioPlayer, version: "1.4")
    private let playSyncProperty = PlaySyncProperty(layerType: .media, contextType: .sound)
    
    // AudioPlayerAgentProtocol
    public weak var displayDelegate: AudioPlayerDisplayDelegate? {
        didSet {
            audioPlayerDisplayManager.delegate = displayDelegate
        }
    }
    
    public var offset: Int? {
        currentPlayer?.offset.truncatedSeconds
    }
    
    public var duration: Int? {
        currentPlayer?.duration.truncatedSeconds
    }
    
    private var lastOffset: TimeIntervallic? {
        currentPlayer?.offset ?? currentMedia?.offset
    }
    
    private var lastDuration: TimeIntervallic? {
        currentPlayer?.duration ?? currentMedia?.duration
    }
    
    public var volume: Float = 1.0 {
        didSet {
            currentPlayer?.volume = volume
        }
    }
    
    public var isPlaying: Bool {
        return audioPlayerState == .playing
    }
    
    // Private
    private let playSyncManager: PlaySyncManageable
    private let contextManager: ContextManageable
    private let focusManager: FocusManageable
    private let directiveSequencer: DirectiveSequenceable
    private let upstreamDataSender: UpstreamDataSendable
    private let audioPlayerPauseTimeout: DispatchTimeInterval
    private lazy var audioPlayerDisplayManager: AudioPlayerDisplayManageable = AudioPlayerDisplayManager(
        audioPlayerPauseTimeout: audioPlayerPauseTimeout,
        audioPlayerAgent: self,
        playSyncManager: playSyncManager
    )
    private let delegates = DelegateSet<AudioPlayerAgentDelegate>()
    
    private let audioPlayerDispatchQueue = DispatchQueue(label: "com.sktelecom.romaine.audioplayer_agent", qos: .userInitiated)
    private lazy var audioPlayerScheduler = SerialDispatchQueueScheduler(
        queue: audioPlayerDispatchQueue,
        internalSerialQueueName: "com.sktelecom.romaine.audioplayer_agent_timer"
    )
    
    private var audioPlayerState: AudioPlayerState = .idle {
        didSet {
            if oldValue != audioPlayerState {
                log.info("AudioPlayerAgent state changed \(oldValue) -> \(audioPlayerState)")
            }
            
            guard let media = self.currentMedia else {
                log.error("AudioPlayerAgentMedia is nil")
                return
            }
            
            // progress report -> pause timer -> `PlaySyncState` -> `AudioPlayerAgentMedia` -> `AudioPlayerAgentDelegate`
            switch audioPlayerState {
            case .playing:
                startProgressReport()
                playSyncManager.cancelTimer(property: playSyncProperty)
            case .stopped, .finished:
                stopProgressReport()
                if media.cancelAssociation {
                    playSyncManager.stopPlay(dialogRequestId: media.dialogRequestId)
                } else {
                    playSyncManager.endPlay(property: playSyncProperty)
                }
                currentPlayer = nil
            case .paused(let temporary):
                stopProgressReport()
                if temporary == false {
                    playSyncManager.startTimer(property: playSyncProperty, duration: audioPlayerPauseTimeout)
                }
            default:
                break
            }
            
            // Notify delegates only if the agent's status changes.
            if oldValue != audioPlayerState {
                delegates.notify { delegate in
                    delegate.audioPlayerAgentDidChange(state: audioPlayerState, dialogRequestId: media.dialogRequestId)
                }
            }
        }
    }
    
    // Current play info
    private var currentMedia: AudioPlayerAgentMedia?
    private var currentPlayer: MediaPlayable?

    // ProgressReporter
    private var intervalReporter: Disposable?
    private var lastReportedOffset: Int = 0
    
    private lazy var disposeBag = DisposeBag()
    
    // Handleable Directives
    private lazy var handleableDirectiveInfos = [
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "Play", blockingPolicy: BlockingPolicy(medium: .audio, isBlocking: false), preFetch: prefetchPlay, directiveHandler: handlePlay, attachmentHandler: handleAttachment),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "Stop", blockingPolicy: BlockingPolicy(medium: .audio, isBlocking: false), directiveHandler: handleStop),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "Pause", blockingPolicy: BlockingPolicy(medium: .audio, isBlocking: false), directiveHandler: handlePause),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "RequestPlayCommand", blockingPolicy: BlockingPolicy(medium: .audio, isBlocking: false), directiveHandler: handleRequestPlayCommand),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "RequestResumeCommand", blockingPolicy: BlockingPolicy(medium: .audio, isBlocking: false), directiveHandler: handleRequestResumeCommand),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "RequestNextCommand", blockingPolicy: BlockingPolicy(medium: .audio, isBlocking: false), directiveHandler: handleRequestNextCommand),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "RequestPreviousCommand", blockingPolicy: BlockingPolicy(medium: .audio, isBlocking: false), directiveHandler: handleRequestPreviousCommand),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "RequestPauseCommand", blockingPolicy: BlockingPolicy(medium: .audio, isBlocking: false), directiveHandler: handleRequestPauseCommand),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "RequestStopCommand", blockingPolicy: BlockingPolicy(medium: .audio, isBlocking: false), directiveHandler: handleRequestStopCommand),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "UpdateMetadata", blockingPolicy: BlockingPolicy(medium: .none, isBlocking: false), directiveHandler: handleUpdateMetadata),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "ShowLyrics", blockingPolicy: BlockingPolicy(medium: .none, isBlocking: false), directiveHandler: handleShowLyrics),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "HideLyrics", blockingPolicy: BlockingPolicy(medium: .none, isBlocking: false), directiveHandler: handleHideLyrics),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "ControlLyricsPage", blockingPolicy: BlockingPolicy(medium: .none, isBlocking: false), directiveHandler: handleControlLyricsPage)
    ]
    
    public init(
        focusManager: FocusManageable,
        upstreamDataSender: UpstreamDataSendable,
        playSyncManager: PlaySyncManageable,
        contextManager: ContextManageable,
        directiveSequencer: DirectiveSequenceable,
        audioPlayerPauseTimeout: DispatchTimeInterval = .milliseconds(600000)
    ) {
        self.focusManager = focusManager
        self.upstreamDataSender = upstreamDataSender
        self.playSyncManager = playSyncManager
        self.contextManager = contextManager
        self.directiveSequencer = directiveSequencer
        self.audioPlayerPauseTimeout = audioPlayerPauseTimeout

        playSyncManager.add(delegate: self)
        contextManager.add(delegate: self)
        focusManager.add(channelDelegate: self)
        directiveSequencer.add(directiveHandleInfos: handleableDirectiveInfos.asDictionary)
    }

    deinit {
        directiveSequencer.remove(directiveHandleInfos: handleableDirectiveInfos.asDictionary)
        currentPlayer?.stop()
    }
}

// MARK: - AudioPlayerAgent + AudioPlayerAgentProtocol

public extension AudioPlayerAgent {
    func add(delegate: AudioPlayerAgentDelegate) {
        delegates.add(delegate)
    }
    
    func remove(delegate: AudioPlayerAgentDelegate) {
        delegates.remove(delegate)
    }
    
    func play() {
        audioPlayerDispatchQueue.async { [weak self] in
            guard let self = self, self.currentPlayer != nil else {
                log.debug("Skip, MediaPlayer not exist.")
                return
            }
            self.currentMedia?.pauseReason = .nothing
            self.focusManager.requestFocus(channelDelegate: self)
        }
    }
    
    func stop() {
        stop(cancelAssociation: true)
    }
    
    @discardableResult func next(completion: ((StreamDataState) -> Void)?) -> String {
        let eventIdentifier = EventIdentifier()
        audioPlayerDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            guard let media = self.currentMedia else { return }
            
            self.sendPlayEvent(media: media, typeInfo: .nextCommandIssued, eventIdentifier: eventIdentifier, completion: completion)
        }
        return eventIdentifier.dialogRequestId
    }
    
    @discardableResult func prev(completion: ((StreamDataState) -> Void)?) -> String {
        let eventIdentifier = EventIdentifier()
        audioPlayerDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            guard let media = self.currentMedia else { return }
            
            self.sendPlayEvent(media: media, typeInfo: .previousCommandIssued, eventIdentifier: eventIdentifier, completion: completion)
        }
        return eventIdentifier.dialogRequestId
    }
    
    func pause() {
        audioPlayerDispatchQueue.async { [weak self] in
            guard let self = self,
                let media = self.currentMedia,
                let player = self.currentPlayer else {
                    return
            }
            switch self.audioPlayerState {
            case .playing:
                self.currentMedia?.pauseReason = .user
                player.pause()
            case .paused:
                self.currentMedia?.pauseReason = .user
                self.audioPlayerState = .paused(temporary: false)
                self.sendPlayEvent(media: media, typeInfo: .playbackPaused)
            default:
                break
            }
        }
    }
    
    func requestFavoriteCommand(current: Bool) {
        guard let media = currentMedia else { return }
        
        audioPlayerDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.sendSettingsEvent(media: media, typeInfo: .favoriteCommandIssued(current: current))
        }
    }

    func requestRepeatCommand(currentMode: AudioPlayerDisplayRepeat) {
        guard let media = currentMedia else { return }
        
        audioPlayerDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.sendSettingsEvent(media: media, typeInfo: .repeatCommandIssued(currentMode: currentMode))
        }
    }
    
    func requestShuffleCommand(current: Bool) {
        guard let media = currentMedia else { return }
        
        audioPlayerDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.sendSettingsEvent(media: media, typeInfo: .shuffleCommandIssued(current: current))
        }
    }
    
    func seek(to offset: Int) {
        audioPlayerDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentPlayer?.seek(to: NuguTimeInterval(seconds: offset))
        }
    }
    
    func notifyUserInteraction() {
        switch audioPlayerState {
        case .stopped, .finished:
            playSyncManager.resetTimer(property: playSyncProperty)
        case .paused(let temporary):
            if temporary == false {
                playSyncManager.startTimer(property: playSyncProperty, duration: audioPlayerPauseTimeout)
            }
        default:
            break
        }
        audioPlayerDisplayManager.notifyUserInteraction()
    }
}

// MARK: - FocusChannelDelegate

extension AudioPlayerAgent: FocusChannelDelegate {
    public func focusChannelPriority() -> FocusChannelPriority {
        return .media
    }
    
    public func focusChannelDidChange(focusState: FocusState) {
        audioPlayerDispatchQueue.sync { [weak self] in
            guard let self = self else { return }
            
            log.info("\(focusState) \(self.audioPlayerState)")
            switch (focusState, self.audioPlayerState) {
            // Directive 에 의한 Pause 인경우 재생하지 않음.
            case (.foreground, .paused):
                if self.currentMedia?.pauseReason != .user {
                    self.currentPlayer?.resume()
                }
            case (.foreground, _):
                self.currentPlayer?.play()
            case (.background, .playing):
                self.currentMedia?.pauseReason = .focus
                self.currentPlayer?.pause()
            // background. idle, pause, stopped, finished 무시
            case (.background, _):
                break
            case (.nothing, .playing),
                 (.nothing, .paused):
                self.stop(cancelAssociation: false)
            // none. idle/stopped/finished 무시
            case (.nothing, _):
                break
            }
        }
    }
}

// MARK: - MediaPlayerDelegate

extension AudioPlayerAgent: MediaPlayerDelegate {
    public func mediaPlayerDidChange(state: MediaPlayerState) {
        audioPlayerDispatchQueue.async { [weak self] in
            log.info("\(state)")
            guard let self = self else { return }
            guard let media = self.currentMedia else { return }
            
            // `AudioPlayerState` -> Event -> `FocusState`
            switch state {
            case .start:
                self.audioPlayerState = .playing
                self.sendPlayEvent(media: media, typeInfo: .playbackStarted)
            case .resume:
                self.audioPlayerState = .playing
                if media.pauseReason != .focus {
                    self.sendPlayEvent(media: media, typeInfo: .playbackResumed)
                }
            case .finish:
                self.saveCurrentPlayerState()
                self.audioPlayerState = .finished
                self.sendPlayEvent(media: media, typeInfo: .playbackFinished) { [weak self] state in
                    // Release focus when stream finished.
                    self?.audioPlayerDispatchQueue.async { [weak self] in
                        guard let self = self else { return }
                        
                        switch state {
                        case .finished where self.currentPlayer == nil:
                            self.releaseFocusIfNeeded()
                        case .error:
                            self.releaseFocusIfNeeded()
                        default:
                            break
                        }
                    }
                }
            case .pause:
                if media.pauseReason != .focus {
                    self.audioPlayerState = .paused(temporary: false)
                    self.sendPlayEvent(media: media, typeInfo: .playbackPaused)
                } else {
                    self.audioPlayerState = .paused(temporary: true)
                }
            case .stop:
                self.audioPlayerState = .stopped
                self.sendPlayEvent(media: media, typeInfo: .playbackStopped(reason: "STOP"))
                self.releaseFocusIfNeeded()
            case .bufferUnderrun, .bufferRefilled:
                break
            case .error(let error):
                log.error("\(state) \(error)")
                self.audioPlayerState = .stopped
                self.sendPlayEvent(media: media, typeInfo: .playbackFailed(error: error))
                self.releaseFocusIfNeeded()
            }
        }
    }
}

// MARK: - ContextInfoDelegate

extension AudioPlayerAgent: ContextInfoDelegate {
    public func contextInfoRequestContext(completion: @escaping (ContextInfo?) -> Void) {
        var payload: [String: AnyHashable?] = [
            "version": capabilityAgentProperty.version,
            "playServiceId": currentMedia?.payload.playServiceId,
            "playerActivity": audioPlayerState.playerActivity,
            // This is a mandatory in Play kit.
            "offsetInMilliseconds": lastOffset?.truncatedMilliSeconds,
            "token": currentMedia?.payload.audioItem.stream.token,
            "lyricsVisible": false
        ]
        payload["durationInMilliseconds"] = lastDuration?.truncatedMilliSeconds
        
        if let playServiceId = currentMedia?.payload.playServiceId {
            let semaphore = DispatchSemaphore(value: 0)
            audioPlayerDisplayManager.isLyricsVisible(playServiceId: playServiceId) { result in
                payload["lyricsVisible"] = result
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + .seconds(5)) == .timedOut {
                log.error("`isLyricsVisible` completion block does not called")
            }
        }
        
        completion(ContextInfo(contextType: .capability, name: capabilityAgentProperty.name, payload: payload.compactMapValues { $0 }))
    }
}

// MARK: - PlaySyncDelegate

extension AudioPlayerAgent: PlaySyncDelegate {
    public func playSyncDidRelease(property: PlaySyncProperty, messageId: String) {
        audioPlayerDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            guard property == self.playSyncProperty, self.currentMedia?.messageId == messageId else { return }
            
            self.stop(cancelAssociation: true)
        }
    }
}

// MARK: - Private (Directive)

private extension AudioPlayerAgent {
    func prefetchPlay() -> PrefetchDirective {
        return { [weak self] directive in
            let payload = try JSONDecoder().decode(AudioPlayerAgentMedia.Payload.self, from: directive.payload)
            
            self?.audioPlayerDispatchQueue.async { [weak self] in
                guard let self = self else { return }
                
                if [.playing, .paused(temporary: true), .paused(temporary: false)].contains(self.audioPlayerState),
                    let media = self.currentMedia, let player = self.currentPlayer,
                    media.payload.audioItem.stream.token == payload.audioItem.stream.token,
                    media.payload.playServiceId == payload.playServiceId {
                    log.debug("Resuming")
                    // Resume and seek
                    self.currentMedia = AudioPlayerAgentMedia(
                        dialogRequestId: directive.header.dialogRequestId,
                        messageId: directive.header.messageId,
                        payload: payload
                    )
                    
                    player.seek(to: NuguTimeInterval(seconds: payload.audioItem.stream.offset))
                } else {
                    self.stopSilently()
                    self.lastReportedOffset = 0
                    self.setMediaPlayer(
                        dialogRequestId: directive.header.dialogRequestId,
                        messageId: directive.header.messageId,
                        payload: payload
                    )
                }
                
                if let media = self.currentMedia {
                    self.playSyncManager.startPlay(
                        property: self.playSyncProperty,
                        info: PlaySyncInfo(
                            playStackServiceId: media.payload.playStackControl?.playServiceId,
                            dialogRequestId: media.dialogRequestId,
                            messageId: media.messageId,
                            duration: NuguTimeInterval(seconds: 7)
                        )
                    )
                    
                    self.audioPlayerDisplayManager.display(
                        payload: payload,
                        messageId: directive.header.messageId,
                        dialogRequestId: directive.header.dialogRequestId
                    )
                }
            }
        }
    }
    
   func handlePlay() -> HandleDirective {
        return { [weak self] directive, completion in
            guard let self = self else {
                completion(.canceled)
                return
            }
            defer { completion(.finished) }
            
            self.focusManager.requestFocus(channelDelegate: self)
        }
    }
    
   func handleStop() -> HandleDirective {
        return { [weak self] _, completion in
            defer { completion(.finished) }
            
            guard let self = self, let media = self.currentMedia else { return }
            guard self.currentPlayer != nil else {
                // Release synchronized layer after playback finished.
                self.playSyncManager.stopPlay(dialogRequestId: media.dialogRequestId)
                return
            }
            
            self.stop(cancelAssociation: true)
        }
    }
    
   func handlePause() -> HandleDirective {
        return { [weak self] _, completion in
            defer { completion(.finished) }
            
            self?.pause()
        }
    }
    
    func handleRequestPlayCommand() -> HandleDirective {
        return { [weak self] directive, completion in
            guard let payloadDictionary = directive.payloadDictionary else {
                completion(.failed("Invalid payload"))
                return
            }
            defer { completion(.finished) }

            self?.sendRequestPlayEvent(referrerDialogRequestId: directive.header.dialogRequestId, typeInfo: .requestPlayCommandIssued(payload: payloadDictionary))
        }
    }
    
    func handleRequestResumeCommand() -> HandleDirective {
        return { [weak self] directive, completion in
            defer { completion(.finished) }
            
            self?.audioPlayerDispatchQueue.async { [weak self] in
                guard let self = self else { return }
                guard let media = self.currentMedia else {
                    self.sendRequestCommandFailedEvent(directive: directive)
                    return
                }
                self.sendPlayEvent(media: media, typeInfo: .requestResumeCommandIssued)
            }
        }
    }
    
    func handleRequestNextCommand() -> HandleDirective {
        return { [weak self] directive, completion in
            defer { completion(.finished) }
            
            self?.audioPlayerDispatchQueue.async { [weak self] in
                guard let self = self else { return }
                guard let media = self.currentMedia else {
                    self.sendRequestCommandFailedEvent(directive: directive)
                    return
                }
                self.sendPlayEvent(media: media, typeInfo: .requestResumeCommandIssued)
            }
        }
    }
    
    func handleRequestPreviousCommand() -> HandleDirective {
        return { [weak self] directive, completion in
            defer { completion(.finished) }
            
            self?.audioPlayerDispatchQueue.async { [weak self] in
                guard let self = self else { return }
                guard let media = self.currentMedia else {
                    self.sendRequestCommandFailedEvent(directive: directive)
                    return
                }
                self.sendPlayEvent(media: media, typeInfo: .requestPreviousCommandIssued)
            }
        }
    }
    
    func handleRequestPauseCommand() -> HandleDirective {
        return { [weak self] directive, completion in
            defer { completion(.finished) }
            
            self?.audioPlayerDispatchQueue.async { [weak self] in
                guard let self = self else { return }
                guard let media = self.currentMedia else {
                    self.sendRequestCommandFailedEvent(directive: directive)
                    return
                }
                self.sendPlayEvent(media: media, typeInfo: .requestPauseCommandIssued)
            }
        }
    }
    
    func handleRequestStopCommand() -> HandleDirective {
        return { [weak self] directive, completion in
            defer { completion(.finished) }
            
            self?.audioPlayerDispatchQueue.async { [weak self] in
                guard let self = self else { return }
                guard let media = self.currentMedia else {
                    self.sendRequestCommandFailedEvent(directive: directive)
                    return
                }
                self.sendPlayEvent(media: media, typeInfo: .requestStopCommandIssued)
            }
        }
    }
    
    func handleUpdateMetadata() -> HandleDirective {
        return { [weak self] directive, completion in
            guard let playServiceId = directive.payloadDictionary?["playServiceId"] as? String else {
                completion(.failed("Invalid payload"))
                return
            }
            defer { completion(.finished) }
            
            self?.audioPlayerDisplayManager.updateMetadata(payload: directive.payload, playServiceId: playServiceId)
        }
    }
    
    func handleShowLyrics() -> HandleDirective {
        return { [weak self] directive, completion in
            guard let playServiceId = directive.payloadDictionary?["playServiceId"] as? String else {
                completion(.failed("Invalid payload"))
                return
            }
            defer { completion(.finished) }

            self?.audioPlayerDisplayManager.showLyrics(playServiceId: playServiceId) { [weak self] isSuccess in
                self?.sendLyricsEvent(
                    playServiceId: playServiceId,
                    referrerDialogRequestId: directive.header.dialogRequestId,
                    typeInfo: isSuccess ? .showLyricsSucceeded : .showLyricsFailed
                )
            }
        }
    }
    
    func handleHideLyrics() -> HandleDirective {
        return { [weak self] directive, completion in
            guard let playServiceId = directive.payloadDictionary?["playServiceId"] as? String else {
                completion(.failed("Invalid payload"))
                return
            }
            defer { completion(.finished) }

            self?.audioPlayerDisplayManager.hideLyrics(playServiceId: playServiceId) { [weak self] isSuccess in
                self?.sendLyricsEvent(
                    playServiceId: playServiceId,
                    referrerDialogRequestId: directive.header.dialogRequestId,
                    typeInfo: isSuccess ? .hideLyricsSucceeded : .hideLyricsFailed
                )
            }
        }
    }
    
    func handleControlLyricsPage() -> HandleDirective {
        return { [weak self] directive, completion in
            guard let payload = try? JSONDecoder().decode(AudioPlayerDisplayControlPayload.self, from: directive.payload) else {
                completion(.failed("Invalid payload"))
                return
            }
            defer { completion(.finished) }

            self?.audioPlayerDisplayManager.controlLyricsPage(payload: payload) { [weak self] isSuccess in
                self?.sendLyricsEvent(
                    playServiceId: payload.playServiceId,
                    referrerDialogRequestId: directive.header.dialogRequestId,
                    typeInfo: isSuccess ? .controlLyricsPageSucceeded(direction: payload.direction) : .controlLyricsPageFailed(direction: payload.direction)
                )
            }
        }
    }
    
    func handleAttachment() -> HandleAttachment {
        return { [weak self] attachment in
            self?.audioPlayerDispatchQueue.async { [weak self] in
                log.info("\(attachment.header.messageId)")
                guard let self = self else { return }
                guard let dataSource = self.currentPlayer as? MediaOpusStreamDataSource,
                    self.currentMedia?.dialogRequestId == attachment.header.dialogRequestId else {
                        log.warning("MediaOpusStreamDataSource not exist or dialogRequesetId not valid")
                    return
                }
                
                do {
                    try dataSource.appendData(attachment.content)
                    
                    if attachment.isEnd {
                        try dataSource.lastDataAppended()
                    }
                } catch {
                    log.error(error)
                }
            }
        }
    }
    
    func stop(cancelAssociation: Bool) {
        audioPlayerDispatchQueue.async { [weak self] in
            guard let self = self, let player = self.currentPlayer else { return }
            
            self.saveCurrentPlayerState()
            self.currentMedia?.cancelAssociation = cancelAssociation
            player.stop()
        }
    }
    
    /// Stop mediaplayer
    func stopSilently() {
        guard let media = currentMedia, let player = currentPlayer else { return }
            
        saveCurrentPlayerState()
        currentMedia?.cancelAssociation = false
        // `AudioPlayerState` -> Event
        player.delegate = nil
        player.stop()
        audioPlayerState = .stopped
        sendPlayEvent(media: media, typeInfo: .playbackStopped(reason: "PLAY_ANOTHER"))
    }
}

// MARK: - Private (Event)

private extension AudioPlayerAgent {
    func sendPlayEvent(
        media: AudioPlayerAgentMedia,
        typeInfo: PlayEvent.TypeInfo,
        eventIdentifier: EventIdentifier = EventIdentifier(),
        completion: ((StreamDataState) -> Void)? = nil
    ) {
        let offset = lastOffset?.truncatedMilliSeconds
        contextManager.getContexts(namespace: capabilityAgentProperty.name) { [weak self] contextPayload in
            guard let self = self else { return }
            
            self.upstreamDataSender.sendEvent(
                PlayEvent(
                    token: media.payload.audioItem.stream.token,
                    offsetInMilliseconds: offset ?? 0, // This is a mandatory in Play kit.
                    playServiceId: media.payload.playServiceId,
                    typeInfo: typeInfo
                ).makeEventMessage(
                    property: self.capabilityAgentProperty,
                    eventIdentifier: eventIdentifier,
                    referrerDialogRequestId: media.dialogRequestId,
                    contextPayload: contextPayload
                ),
                completion: completion
            )
        }
    }
    
    func sendRequestCommandFailedEvent(directive: Downstream.Directive) {
        let eventIdentifier = EventIdentifier()
        contextManager.getContexts(namespace: capabilityAgentProperty.name) { [weak self] contextPayload in
            guard let self = self else { return }
            
            self.upstreamDataSender.sendEvent(
                RequestPlayEvent(
                    typeInfo: .requestCommandFailed(state: self.audioPlayerState, directiveType: directive.header.type)
                ).makeEventMessage(
                    property: self.capabilityAgentProperty,
                    eventIdentifier: eventIdentifier,
                    referrerDialogRequestId: directive.header.dialogRequestId,
                    contextPayload: contextPayload
                )
            )
        }
    }

    func sendRequestPlayEvent(
        referrerDialogRequestId: String,
        typeInfo: RequestPlayEvent.TypeInfo,
        completion: ((StreamDataState) -> Void)? = nil
    ) {
        let eventIdentifier = EventIdentifier()
        contextManager.getContexts(namespace: capabilityAgentProperty.name) { [weak self] contextPayload in
            guard let self = self else { return }
            
            self.upstreamDataSender.sendEvent(
                RequestPlayEvent(
                    typeInfo: typeInfo
                ).makeEventMessage(
                    property: self.capabilityAgentProperty,
                    eventIdentifier: eventIdentifier,
                    referrerDialogRequestId: referrerDialogRequestId,
                    contextPayload: contextPayload
                ),
                completion: completion
            )
        }
    }

    func sendSettingsEvent(
        media: AudioPlayerAgentMedia,
        typeInfo: SettingsEvent.TypeInfo,
        completion: ((StreamDataState) -> Void)? = nil
    ) {
        let eventIdentifier = EventIdentifier()
        contextManager.getContexts(namespace: capabilityAgentProperty.name) { [weak self] contextPayload in
            guard let self = self else { return }
            
            self.upstreamDataSender.sendEvent(
                SettingsEvent(
                    playServiceId: media.payload.playServiceId,
                    typeInfo: typeInfo
                ).makeEventMessage(
                    property: self.capabilityAgentProperty,
                    eventIdentifier: eventIdentifier,
                    referrerDialogRequestId: media.dialogRequestId,
                    contextPayload: contextPayload
                ),
                completion: completion
            )
        }
    }
    
    func sendLyricsEvent(
        playServiceId: String,
        referrerDialogRequestId: String,
        typeInfo: LyricsEvent.TypeInfo,
        completion: ((StreamDataState) -> Void)? = nil
    ) {
        let eventIdentifier = EventIdentifier()
        contextManager.getContexts(namespace: capabilityAgentProperty.name) { [weak self] contextPayload in
            guard let self = self else { return }
            
            self.upstreamDataSender.sendEvent(
                LyricsEvent(
                    playServiceId: playServiceId,
                    typeInfo: typeInfo
                ).makeEventMessage(
                    property: self.capabilityAgentProperty,
                    eventIdentifier: eventIdentifier,
                    referrerDialogRequestId: referrerDialogRequestId,
                    contextPayload: contextPayload
                ),
                completion: completion
            )
        }
    }
}

// MARK: - Private(FocusManager)

private extension AudioPlayerAgent {
    func releaseFocusIfNeeded() {
        guard [.idle, .stopped, .finished].contains(self.audioPlayerState) else {
            log.info("Not permitted in current state, \(audioPlayerState)")
            return
        }
        focusManager.releaseFocus(channelDelegate: self)
    }
}

// MARK: - Private (Timer)

private extension AudioPlayerAgent {
    func startProgressReport() {
        stopProgressReport()
        guard let media = currentMedia else { return }
        let delayReportTime = media.payload.audioItem.stream.delayReportTime ?? -1
        let intervalReportTime = media.payload.audioItem.stream.intervalReportTime ?? -1
        guard delayReportTime > 0 || intervalReportTime > 0 else { return }
        
        log.debug("delayReportTime: \(delayReportTime) intervalReportTime: \(intervalReportTime)")
        intervalReporter = Observable<Int>
            .interval(.milliseconds(100), scheduler: audioPlayerScheduler)
            .map({ [weak self] (_) -> Int in
                let offset = self?.currentPlayer?.offset.seconds ?? 0.0
                return Int(ceil(offset))
            })
            .filter { [weak self] offset in
                guard let self = self else { return false }
                guard offset > 0 else { return false }
                // Current offset can be smaller than the last offset after seeking.
                guard offset > self.lastReportedOffset else {
                    self.lastReportedOffset = offset
                    return false
                }

                return true
            }
            .subscribe(onNext: { [weak self] (offset) in
                guard let self = self else { return }
                
                // Check if there is any report target between last offset and current offset.
                let offsetRange = (self.lastReportedOffset + 1...offset)
                if delayReportTime > 0, offsetRange.contains(delayReportTime) {
                    self.sendPlayEvent(media: media, typeInfo: .progressReportDelayElapsed)
                }
                if intervalReportTime > 0, offsetRange.contains(intervalReportTime * (self.lastReportedOffset / intervalReportTime + 1)) {
                    self.sendPlayEvent(media: media, typeInfo: .progressReportIntervalElapsed)
                }
                self.lastReportedOffset = offset
            })
        
        intervalReporter?.disposed(by: disposeBag)
    }
    
    func stopProgressReport() {
        intervalReporter?.dispose()
    }
}

// MARK: - Private (Media)

private extension AudioPlayerAgent {
    /// set mediaplayer
    func setMediaPlayer(dialogRequestId: String, messageId: String, payload: AudioPlayerAgentMedia.Payload) {
        switch payload.sourceType {
        case .url:
            guard let url = payload.audioItem.stream.url else {
                log.error("Invalid payload")
                return
            }
            let mediaPlayer = MediaPlayer()
            mediaPlayer.setSource(
                url: url,
                offset: NuguTimeInterval(seconds: payload.audioItem.stream.offset),
                cacheKey: payload.cacheKey
            )
            currentPlayer = mediaPlayer
            currentMedia = AudioPlayerAgentMedia(
                dialogRequestId: dialogRequestId,
                messageId: messageId,
                payload: payload
            )
        case .attachment:
            do {
                currentPlayer = try OpusPlayer()
                currentMedia = AudioPlayerAgentMedia(
                    dialogRequestId: dialogRequestId,
                    messageId: messageId,
                    payload: payload
                )
            } catch {
                // TODO: 실패시 예외처리 필요한지 확인
                log.error("Opus player initiation error: \(error)")
            }
        case .none:
            log.error("Invalid payload")
        }

        currentPlayer?.delegate = self
        currentPlayer?.volume = volume
    }
    
    // Keep the offset and duration to be sent with playback events.
    func saveCurrentPlayerState() {
        currentMedia?.offset = currentPlayer?.offset
        currentMedia?.duration = currentPlayer?.duration
    }
}
