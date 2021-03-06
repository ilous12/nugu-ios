//
//  SharedBuffer.swift
//  NuguCore
//
//  Created by DCs-OfficeMBP on 01/05/2019.
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
import AVFoundation
import RxSwift

/**
 SharedBuffer is based on RingBuffer.
 It can have only one writer and multiple reader.
 */
class SharedBuffer<Element> {
    private var array: [Element?]
    @Atomic private var lastIndex: SharedBufferIndex

    private var writer: Writer?
    private let writeQueue = DispatchQueue(label: "com.sktelecom.romaine.ring_buffer.write")
    private let writeSubject: PublishSubject<Element> = PublishSubject<Element>()
    private var readers: NSHashTable<Reader> = NSHashTable.weakObjects()
    private let disposeBag = DisposeBag()
    
    init(capacity: Int) {
        array = [Element?](repeating: nil, count: capacity)
        lastIndex = SharedBufferIndex(bufferSize: array.count)
    }
    
    private func write(_ element: Element) {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.array[self.lastIndex.value] = element
            self.lastIndex += 1
            
            self.writeSubject.onNext(element)
        }
    }
    
    private func read(index: SharedBufferIndex) -> Observable<Element> {
        return Observable<Element>.create { [weak self] (observer) -> Disposable in
            let disposable = Disposables.create()
            
            guard let self = self else { return disposable }
            guard index < self.lastIndex, let value = self.array[index.value] else {
                self.writeSubject
                    .take(1)
                    .subscribe(onNext: { (element) in
                        observer.onNext(element)
                        observer.onCompleted()
                    }).disposed(by: self.disposeBag)
                
                return disposable
            }
            
            observer.onNext(value)
            observer.onCompleted()
            
            return disposable
        }
    }
    
    func makeBufferWriter() -> Writer {
        writer = Writer(buffer: self)
        return writer!
    }
    
    func makeBufferReader() -> Reader {
        return Reader(buffer: self)
    }
}

// MARK: - Writer/Reader
extension SharedBuffer {
    class Writer {
        private weak var buffer: SharedBuffer?
        
        init(buffer: SharedBuffer) {
            self.buffer = buffer
        }
        
        func write(_ element: Element) throws {
            guard buffer?.writer === self else {
                throw SharedBufferError.writePermissionDenied
            }
            
            buffer?.write(element)
        }
        
        func finish() {
            log.debug("readers cnt: \(buffer?.readers.allObjects.count ?? 0)")
            if let buffer = buffer, buffer.writer === self {
                buffer.writer = nil
            }
        }
    }
    
    class Reader {
        private let buffer: SharedBuffer
        private let readQueue = DispatchQueue(label: "com.sktelecom.romaine.ring_buffer.reader")
        @Atomic private var readIndex: SharedBufferIndex
        private let disposeBag = DisposeBag()
        
        init(buffer: SharedBuffer) {
            self.buffer = buffer
            self.readIndex = buffer.lastIndex
            buffer.readers.add(self)
        }
        
        func read(complete: @escaping (Result<Element, Error>) -> Void) {
            readQueue.async { [weak self] in
                guard let self = self else { return }
                
                self.buffer.read(index: self.readIndex)
                    .take(1)
                    .observeOn(SerialDispatchQueueScheduler(queue: self.readQueue, internalSerialQueueName: "rx-"+self.readQueue.label))
                    .subscribe(onNext: { [weak self] (writtenElement) in
                        self?.readIndex += 1
                        complete(.success(writtenElement))
                    }).disposed(by: self.disposeBag)
            }
        }
    }
}
