import 'dart:async';

/// A file in a review
class ReviewFile {
  final String path;
  final int added;
  const ReviewFile(this.path, {this.added = 0});

  @override
  String toString() => '$path (+${added})';
}

Future<void> main() async {
  final files = <ReviewFile>[const ReviewFile('lib/main.dart', added: 3)];
  await Future.delayed(const Duration(milliseconds: 200));
  print(files.where((f) => f.added > 0).length);
}
