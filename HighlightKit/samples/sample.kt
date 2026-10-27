package review

import kotlinx.coroutines.delay

/** A file in a review */
data class ReviewFile(val path: String, val priority: Priority = Priority.SKIM)

enum class Priority { CRITICAL, REVIEW, SKIM }

suspend fun send(files: List<ReviewFile>): Int {
    delay(200L)
    val critical = files.count { it.priority == Priority.CRITICAL }
    println("Sent ${files.size} files, $critical critical\n")
    return if (critical > 0) 1 else 0
}
