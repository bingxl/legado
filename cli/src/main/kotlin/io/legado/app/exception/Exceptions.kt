package io.legado.app.exception

/**
 * 不记录错误堆栈的报错
 */
open class NoStackTraceException(msg: String) : Exception(msg) {

    override fun fillInStackTrace(): Throwable {
        stackTrace = EMPTY_STACK
        return this
    }

    companion object {
        private val EMPTY_STACK = emptyArray<StackTraceElement>()
    }
}

class ContentEmptyException(msg: String) : NoStackTraceException(msg)

class TocEmptyException(msg: String) : NoStackTraceException(msg)

class EmptyFileException(msg: String) : NoStackTraceException(msg)

class InvalidBooksDirException(msg: String) : NoStackTraceException(msg)

class RegexTimeoutException(msg: String) : NoStackTraceException(msg)

class ConcurrentException(msg: String, val waitTime: Int) : NoStackTraceException(msg)
