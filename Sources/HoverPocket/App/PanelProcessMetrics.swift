import AppKit

enum PanelProcessMetrics {
    static func processTaskSnapshot() throws -> (threadCount: Int, residentMiB: Double) {
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.size
        let readSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                getpid(),
                PROC_PIDTASKINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard readSize == expectedSize else {
            throw PanelSoakVerificationError.failed("panel_soak_task_readback_failed")
        }
        return (
            Int(info.pti_threadnum),
            Double(info.pti_resident_size) / 1_048_576
        )
    }

    static func processSocketCount() throws -> Int {
        errno = 0
        let requiredSize = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard requiredSize >= 0, requiredSize > 0 || errno == 0 else {
            throw PanelSoakVerificationError.failed("panel_soak_socket_readback_failed")
        }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: max(1, Int(requiredSize) / MemoryLayout<proc_fdinfo>.size)
        )
        errno = 0
        let readSize = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(
                getpid(),
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard readSize >= 0, readSize > 0 || errno == 0 else {
            throw PanelSoakVerificationError.failed("panel_soak_socket_readback_failed")
        }
        let count = Int(readSize) / MemoryLayout<proc_fdinfo>.size
        return descriptors.prefix(count).filter { $0.proc_fdtype == PROX_FDTYPE_SOCKET }.count
    }

    static func childProcessCount() throws -> Int {
        errno = 0
        let requiredSize = proc_listpids(
            UInt32(PROC_PPID_ONLY),
            UInt32(getpid()),
            nil,
            0
        )
        guard requiredSize >= 0, requiredSize > 0 || errno == 0 else {
            throw PanelSoakVerificationError.failed("panel_soak_child_readback_failed")
        }
        var processIdentifiers = [pid_t](
            repeating: 0,
            count: max(1, Int(requiredSize) / MemoryLayout<pid_t>.size)
        )
        errno = 0
        let readSize = processIdentifiers.withUnsafeMutableBytes { buffer in
            proc_listpids(
                UInt32(PROC_PPID_ONLY),
                UInt32(getpid()),
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard readSize >= 0, readSize > 0 || errno == 0 else {
            throw PanelSoakVerificationError.failed("panel_soak_child_readback_failed")
        }
        let count = Int(readSize) / MemoryLayout<pid_t>.size
        return processIdentifiers.prefix(count).filter { $0 > 0 }.count
    }
}
