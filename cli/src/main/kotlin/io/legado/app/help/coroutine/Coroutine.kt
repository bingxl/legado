package io.legado.app.help.coroutine

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.awaitCancellation
import kotlin.coroutines.CoroutineContext

/**
 * 链式协程的桌面版实现：保留 App 的同名 API（async/onSuccess/onError/await），
 * 去掉 Android 主线程调度（CLI 里 executeContext 默认就是 IO）。
 */
@Suppress("unused", "MemberVisibilityCanBePrivate")
class Coroutine<T>(
    private val scope: CoroutineScope,
    context: CoroutineContext = Dispatchers.IO,
    startOption: CoroutineStart = CoroutineStart.DEFAULT,
    private val executeContext: CoroutineContext = Dispatchers.Default,
    private val semaphore: Semaphore? = null,
    block: suspend CoroutineScope.() -> T
) {

    companion object {

        private val DEFAULT = CoroutineScope(Dispatchers.IO)

        fun <T> async(
            scope: CoroutineScope = DEFAULT,
            context: CoroutineContext = Dispatchers.IO,
            start: CoroutineStart = CoroutineStart.DEFAULT,
            executeContext: CoroutineContext = Dispatchers.Default,
            semaphore: Semaphore? = null,
            block: suspend CoroutineScope.() -> T
        ): Coroutine<T> {
            return Coroutine(scope, context, start, executeContext, semaphore, block)
        }
    }

    private val deferred = CompletableDeferred<T>()

    private var success: ((T) -> Unit)? = null
    private var error: ((Throwable) -> Unit)? = null
    private var finally: (() -> Unit)? = null
    private var errorReturn: (() -> T?)? = null

    private val job: Job = scope.launch(context, startOption) {
        try {
            val value = if (semaphore != null) {
                semaphore.withPermit { block() }
            } else {
                block()
            }
            deferred.complete(value)
            withContext(executeContext) { success?.invoke(value) }
        } catch (e: CancellationException) {
            deferred.cancel(e)
            throw e
        } catch (e: Throwable) {
            val fallback = errorReturn?.invoke()
            if (fallback != null) {
                deferred.complete(fallback)
            } else {
                deferred.completeExceptionally(e)
            }
            withContext(executeContext) { error?.invoke(e) }
        } finally {
            withContext(executeContext) { finally?.invoke() }
        }
    }

    val isCancelled: Boolean get() = job.isCancelled

    val isActive: Boolean get() = job.isActive

    val isCompleted: Boolean get() = job.isCompleted

    fun timeout(timeMillis: Long): Coroutine<T> = this

    fun timeout(timeMillis: () -> Long): Coroutine<T> = this

    fun onErrorReturn(value: T?): Coroutine<T> {
        errorReturn = { value }
        return this
    }

    fun onErrorReturn(value: () -> T?): Coroutine<T> {
        errorReturn = value
        return this
    }

    fun onStart(block: () -> Unit): Coroutine<T> = apply { block() }

    fun onSuccess(block: (T) -> Unit): Coroutine<T> {
        success = block
        return this
    }

    fun onError(block: (Throwable) -> Unit): Coroutine<T> {
        error = block
        return this
    }

    fun onFinally(block: () -> Unit): Coroutine<T> {
        finally = block
        return this
    }

    fun onCancel(block: () -> Unit): Coroutine<T> = this

    fun cancel() {
        job.cancel()
    }

    suspend fun await(): T = deferred.await()
}
