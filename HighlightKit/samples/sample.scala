package review

import scala.util.matching.Regex

/** A hunk of a diff */
final case class Hunk(newStart: Int, lines: Vector[String]):
  def contains(line: Int): Boolean = line >= newStart && line < newStart + lines.size

object Hunk:
  private val Header: Regex = raw"@@ -(\d+),(\d+) \+(\d+)".r

  def parse(text: String): Option[Int] = text match
    case Header(_, _, start) => Some(start.toInt)
    case _                   => None // not a hunk header

@main def run(): Unit = println(s"${Hunk(12, Vector("a")).contains(12)}")
