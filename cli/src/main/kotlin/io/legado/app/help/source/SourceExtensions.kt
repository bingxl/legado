package io.legado.app.help.source

import com.script.rhino.RhinoScriptEngine
import io.legado.app.constant.BookSourceType
import io.legado.app.constant.BookType
import io.legado.app.constant.SourceType
import io.legado.app.data.entities.BaseSource
import io.legado.app.data.entities.BookSource
import io.legado.app.model.SharedJsScope
import org.mozilla.javascript.Scriptable
import kotlin.coroutines.CoroutineContext

/**
 * 书源扩展：作用域、类型映射等
 */
fun BaseSource.getShareScope(coroutineContext: CoroutineContext? = null): Scriptable? {
    return SharedJsScope.getScope(jsLib, coroutineContext)
}

fun BaseSource.getSourceType(): Int {
    return when (this) {
        is BookSource -> SourceType.book
        else -> SourceType.book
    }
}

fun BookSource.getBookType(): Int {
    return when (bookSourceType) {
        BookSourceType.file -> BookType.text or BookType.webFile
        BookSourceType.image -> BookType.image
        BookSourceType.audio -> BookType.audio
        else -> BookType.text
    }
}

fun BookSource.exploreKindsJson(): String {
    return exploreUrl.takeIf { it?.trim()?.startsWith("[") == true } ?: ""
}

@Suppress("unused")
private val unusedEngine = RhinoScriptEngine
