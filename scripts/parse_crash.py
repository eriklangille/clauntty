#!/usr/bin/env python3
"""
Parse iOS crash reports (.ips files) and display relevant information.

Usage:
    uv run scripts/parse_crash.py [path_to_ips_file]
    uv run scripts/parse_crash.py --latest
    uv run scripts/parse_crash.py --latest 3  # Show last 3 crashes

The .ips format contains a header JSON object followed by the main crash data.
"""

import json
import sys
import os
from pathlib import Path
from datetime import datetime


def parse_ips_file(filepath: str) -> dict:
    """Parse an .ips file which contains multiple JSON objects."""
    with open(filepath, 'r') as f:
        content = f.read()

    # .ips files have a header JSON on line 1, then the main crash JSON
    lines = content.strip().split('\n')

    # Try to find where the main JSON starts (usually line 2)
    header = None
    crash_data = None

    try:
        header = json.loads(lines[0])
    except json.JSONDecodeError:
        pass

    # The rest is the main crash JSON
    if len(lines) > 1:
        main_json = '\n'.join(lines[1:])
        try:
            crash_data = json.loads(main_json)
        except json.JSONDecodeError as e:
            # Try parsing just line by line for older formats
            for i, line in enumerate(lines):
                try:
                    data = json.loads(line)
                    if 'threads' in data or 'exception' in data:
                        crash_data = data
                        break
                except json.JSONDecodeError:
                    continue

    return {'header': header, 'crash': crash_data}


def find_crash_origin(data: dict) -> list:
    """Find the original crash site by skipping panic/signal handler frames."""
    crash = data.get('crash', {})
    threads = crash.get('threads', [])
    used_images = crash.get('usedImages', [])

    crashed_thread = None
    for t in threads:
        if t.get('triggered'):
            crashed_thread = t
            break

    if not crashed_thread:
        return []

    frames = crashed_thread.get('frames', [])
    panic_keywords = ['panic', 'abort', 'sigtramp', 'signalhandler', 'pthread_kill',
                      'ubsan', 'asan', 'breakpad', 'exception']

    origin_frames = []
    for i, frame in enumerate(frames):
        symbol = frame.get('symbol', '')
        img_idx = frame.get('imageIndex', 0)
        img_offset = frame.get('imageOffset', 0)

        if img_idx < len(used_images):
            img_path = used_images[img_idx].get('path', '')
            img_name = Path(img_path).name if img_path else f'image_{img_idx}'
        else:
            img_name = f'image_{img_idx}'

        is_panic = any(kw in symbol.lower() for kw in panic_keywords)
        if not is_panic and symbol:
            origin_frames.append({
                'index': i,
                'symbol': symbol,
                'image': img_name,
                'offset': img_offset
            })

    return origin_frames


def format_crash_report(data: dict, filepath: str) -> str:
    """Format crash data into readable output."""
    output = []
    header = data.get('header', {})
    crash = data.get('crash', {})

    # File info
    output.append(f"{'='*60}")
    output.append(f"Crash Report: {Path(filepath).name}")
    output.append(f"{'='*60}")

    # Header info
    if header:
        output.append(f"App: {header.get('app_name', 'Unknown')}")
        output.append(f"Version: {header.get('app_version', 'Unknown')}")
        timestamp = header.get('timestamp')
        if timestamp:
            output.append(f"Time: {timestamp}")

    if not crash:
        output.append("\nCould not parse crash data")
        return '\n'.join(output)

    # Exception info
    exception = crash.get('exception', {})
    if exception:
        output.append(f"\nException Type: {exception.get('type', 'Unknown')}")
        output.append(f"Exception Subtype: {exception.get('subtype', 'N/A')}")
        codes = exception.get('codes', '')
        if codes:
            output.append(f"Exception Codes: {codes}")
        signal = exception.get('signal', '')
        if signal:
            output.append(f"Signal: {signal}")

    # Termination info
    termination = crash.get('termination', {})
    if termination:
        output.append(f"\nTermination Reason: {termination.get('reason', 'N/A')}")

    # Find crashed thread
    threads = crash.get('threads', [])
    crashed_thread = None
    crashed_thread_idx = None

    for i, thread in enumerate(threads):
        if thread.get('triggered', False):
            crashed_thread = thread
            crashed_thread_idx = thread.get('id', i)
            break

    if crashed_thread:
        output.append(f"\n{'='*60}")
        output.append(f"Crashed Thread: {crashed_thread_idx}")
        if crashed_thread.get('name'):
            output.append(f"Thread Name: {crashed_thread.get('name')}")
        output.append(f"{'='*60}")

        frames = crashed_thread.get('frames', [])
        used_images = crash.get('usedImages', [])

        # Filter out panic loop frames to find the original crash site
        # Look for patterns like repeated panic/signal handler sequences
        panic_symbols = {'panicExtra', 'defaultPanic', 'SignalHandler', '_sigtramp',
                        'pthread_kill', 'abort', '__ubsan_handle'}

        filtered_frames = []
        seen_panic_sequence = False
        panic_count = 0

        for frame in frames:
            symbol = frame.get('symbol', '')
            is_panic_frame = any(ps in symbol for ps in panic_symbols)

            if is_panic_frame:
                panic_count += 1
                if panic_count <= 8:  # Show first panic sequence
                    filtered_frames.append(frame)
                elif not seen_panic_sequence:
                    filtered_frames.append({'symbol': f'... ({panic_count - 8} more panic frames) ...'})
                    seen_panic_sequence = True
            else:
                filtered_frames.append(frame)
                panic_count = 0

        output.append(f"\nStack Trace ({len(frames)} total frames, showing {len(filtered_frames)} relevant):")
        output.append("-" * 60)

        for i, frame in enumerate(filtered_frames[:50]):
            symbol = frame.get('symbol', '')
            image_idx = frame.get('imageIndex', 0)
            image_offset = frame.get('imageOffset', 0)

            # Try to get image name
            image_name = ''
            if image_idx < len(used_images):
                image_path = used_images[image_idx].get('path', '')
                image_name = Path(image_path).name if image_path else f'image_{image_idx}'

            if symbol:
                # Truncate long symbols
                if len(symbol) > 100:
                    symbol = symbol[:97] + '...'
                output.append(f"  {i:2d}: {symbol}")
                if image_name and image_offset:
                    output.append(f"      ({image_name} + {image_offset})")
            else:
                output.append(f"  {i:2d}: {image_name} + {image_offset}")

        # Look for the likely crash origin (first non-panic frame after panic sequence)
        origin_frame = None
        in_panic = True
        for frame in frames:
            symbol = frame.get('symbol', '')
            is_panic = any(ps in symbol for ps in panic_symbols)
            if in_panic and not is_panic:
                origin_frame = frame
                break

        if origin_frame:
            origin_symbol = origin_frame.get('symbol', 'unknown')
            output.append(f"\n>>> LIKELY CRASH ORIGIN: {origin_symbol}")
    else:
        output.append("\nNo crashed thread found")

    # Show other relevant info
    asi = crash.get('asi', {})
    if asi:
        output.append(f"\n{'='*60}")
        output.append("Application Specific Information:")
        output.append("-" * 60)
        for key, value in asi.items():
            if isinstance(value, list):
                for item in value:
                    output.append(f"  {item}")
            else:
                output.append(f"  {key}: {value}")

    return '\n'.join(output)


def get_latest_crashes(count: int = 1) -> list:
    """Get paths to the most recent Clauntty crash reports."""
    crash_dir = Path.home() / "Library/Logs/DiagnosticReports"
    if not crash_dir.exists():
        return []

    crashes = list(crash_dir.glob("Clauntty-*.ips"))
    crashes.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return crashes[:count]


def main():
    args = sys.argv[1:]

    if not args:
        print("Usage:")
        print("  uv run scripts/parse_crash.py <path_to_ips_file>")
        print("  uv run scripts/parse_crash.py --latest [count]")
        print("  uv run scripts/parse_crash.py --origin [--latest]  # Show only non-panic frames")
        print("  uv run scripts/parse_crash.py --raw [--latest]     # Show raw top/bottom frames")
        print("  uv run scripts/parse_crash.py --threads [--latest] # Show all threads (useful for recursive panics)")
        print()
        print("Examples:")
        print("  uv run scripts/parse_crash.py ~/Library/Logs/DiagnosticReports/Clauntty-2025-01-01-120000.ips")
        print("  uv run scripts/parse_crash.py --latest")
        print("  uv run scripts/parse_crash.py --latest 3")
        print("  uv run scripts/parse_crash.py --origin --latest")
        print("  uv run scripts/parse_crash.py --raw --latest")
        print("  uv run scripts/parse_crash.py --threads --latest")
        sys.exit(1)

    # Parse flags
    show_origin = '--origin' in args
    show_raw = '--raw' in args
    show_threads = '--threads' in args
    if show_origin:
        args = [a for a in args if a != '--origin']
    if show_raw:
        args = [a for a in args if a != '--raw']
    if show_threads:
        args = [a for a in args if a != '--threads']

    filepaths = []

    if not args or args[0] == '--latest':
        count = int(args[1]) if len(args) > 1 and args[0] == '--latest' else 1
        filepaths = get_latest_crashes(count)
        if not filepaths:
            print("No Clauntty crash reports found in ~/Library/Logs/DiagnosticReports/")
            sys.exit(1)
    else:
        filepath = args[0]
        if not os.path.exists(filepath):
            print(f"File not found: {filepath}")
            sys.exit(1)
        filepaths = [Path(filepath)]

    for filepath in filepaths:
        try:
            data = parse_ips_file(str(filepath))

            if show_threads:
                # Show all threads to find the actual crash cause
                crash = data.get('crash', {})
                threads = crash.get('threads', [])
                used_images = crash.get('usedImages', [])

                print(f"{'='*60}")
                print(f"All Threads: {Path(filepath).name}")
                print(f"Total threads: {len(threads)}")
                print(f"{'='*60}")

                # Skip panic symbols for cleaner output
                panic_symbols = {'panicExtra', 'defaultPanic', 'SignalHandler', '_sigtramp',
                                'pthread_kill', 'abort', '__ubsan_handle', 'breakpad'}

                for t_idx, thread in enumerate(threads):
                    frames = thread.get('frames', [])
                    triggered = thread.get('triggered', False)
                    thread_name = thread.get('name', '')
                    thread_id = thread.get('id', t_idx)

                    # Check if this thread has interesting (non-panic) frames
                    interesting_frames = []
                    for frame in frames[:30]:
                        symbol = frame.get('symbol', '')
                        is_panic = any(ps in symbol for ps in panic_symbols)
                        if symbol and not is_panic:
                            interesting_frames.append(frame)

                    # Skip threads with only panic frames or no symbols
                    if not interesting_frames and not triggered:
                        continue

                    marker = " <<< CRASHED" if triggered else ""
                    print(f"\n--- Thread {thread_id}{' (' + thread_name + ')' if thread_name else ''}{marker} ---")
                    print(f"    Frames: {len(frames)}, Interesting: {len(interesting_frames)}")

                    # Show first few interesting frames
                    for i, frame in enumerate(interesting_frames[:10]):
                        symbol = frame.get('symbol', '<no symbol>')
                        img_idx = frame.get('imageIndex', 0)
                        if img_idx < len(used_images):
                            img_name = Path(used_images[img_idx].get('path', '')).name
                        else:
                            img_name = f'image_{img_idx}'
                        print(f"      [{i:2d}] {symbol[:70]}")
                        if img_name:
                            print(f"           ({img_name})")

                    if len(interesting_frames) > 10:
                        print(f"      ... {len(interesting_frames) - 10} more frames ...")

            elif show_raw:
                # Show all frames raw
                crash = data.get('crash', {})
                threads = crash.get('threads', [])
                used_images = crash.get('usedImages', [])

                crashed_thread = None
                for t in threads:
                    if t.get('triggered'):
                        crashed_thread = t
                        break

                if crashed_thread:
                    frames = crashed_thread.get('frames', [])
                    print(f"{'='*60}")
                    print(f"Raw Stack: {Path(filepath).name}")
                    print(f"Thread: {crashed_thread.get('name', 'unknown')}")
                    print(f"Total frames: {len(frames)}")
                    print(f"{'='*60}")

                    # Show first 20 and last 20 frames
                    print("\n--- Top of stack (most recent) ---")
                    for i, frame in enumerate(frames[:20]):
                        symbol = frame.get('symbol', '<no symbol>')
                        img_idx = frame.get('imageIndex', 0)
                        if img_idx < len(used_images):
                            img_name = Path(used_images[img_idx].get('path', '')).name
                        else:
                            img_name = f'image_{img_idx}'
                        print(f"  [{i:3d}] {symbol[:80]}")
                        print(f"        ({img_name})")

                    if len(frames) > 40:
                        print(f"\n  ... {len(frames) - 40} frames omitted ...")

                    print("\n--- Bottom of stack (oldest / crash origin) ---")
                    start = max(20, len(frames) - 20)
                    for i, frame in enumerate(frames[start:], start):
                        symbol = frame.get('symbol', '<no symbol>')
                        img_idx = frame.get('imageIndex', 0)
                        if img_idx < len(used_images):
                            img_name = Path(used_images[img_idx].get('path', '')).name
                        else:
                            img_name = f'image_{img_idx}'
                        print(f"  [{i:3d}] {symbol[:80]}")
                        print(f"        ({img_name})")
            elif show_origin:
                # Show only crash origin frames (non-panic)
                print(f"{'='*60}")
                print(f"Crash Origin: {Path(filepath).name}")
                print(f"{'='*60}")

                origin_frames = find_crash_origin(data)
                if origin_frames:
                    print(f"\nFound {len(origin_frames)} non-panic frames:")
                    print("-" * 60)
                    for f in origin_frames[:30]:
                        print(f"  [{f['index']:3d}] {f['symbol']}")
                        print(f"        ({f['image']} + {f['offset']})")
                else:
                    print("\nNo non-panic frames found (entire stack is panic handlers)")
            else:
                report = format_crash_report(data, str(filepath))
                print(report)

            print()
        except Exception as e:
            print(f"Error parsing {filepath}: {e}")
            import traceback
            traceback.print_exc()


if __name__ == '__main__':
    main()
