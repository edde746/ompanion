import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';

/// Rebuilds with every new view of [session]. The builder always gets the session's current view, also
/// right after [session] changes.
class SessionViewBuilder extends StatefulWidget {
  const SessionViewBuilder({super.key, required this.session, required this.builder});

  final LiveSession session;
  final Widget Function(BuildContext context, SessionView view) builder;

  @override
  State<SessionViewBuilder> createState() => _SessionViewBuilderState();
}

class _SessionViewBuilderState extends State<SessionViewBuilder> {
  StreamSubscription<SessionView>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(SessionViewBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      unawaited(_subscription?.cancel());
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.session.views.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.session.view);
}

/// Rebuilds only when [select] of the session's view changes (`==`), e.g. a sidebar badge that must not
/// rebuild per streamed token.
class SessionViewSelector<T> extends StatefulWidget {
  const SessionViewSelector({super.key, required this.session, required this.select, required this.builder});

  final LiveSession session;
  final T Function(SessionView view) select;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<SessionViewSelector<T>> createState() => _SessionViewSelectorState<T>();
}

class _SessionViewSelectorState<T> extends State<SessionViewSelector<T>> {
  StreamSubscription<SessionView>? _subscription;
  late T _value;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(SessionViewSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      unawaited(_subscription?.cancel());
      _subscribe();
    } else {
      _value = widget.select(widget.session.view);
    }
  }

  void _subscribe() {
    _value = widget.select(widget.session.view);
    _subscription = widget.session.views.listen((view) {
      final value = widget.select(view);
      if (value != _value && mounted) setState(() => _value = value);
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

/// Rebuilds with every new link state of [session].
class LinkStateBuilder extends StatefulWidget {
  const LinkStateBuilder({super.key, required this.session, required this.builder});

  final LiveSession session;
  final Widget Function(BuildContext context, LinkState state) builder;

  @override
  State<LinkStateBuilder> createState() => _LinkStateBuilderState();
}

class _LinkStateBuilderState extends State<LinkStateBuilder> {
  StreamSubscription<LinkState>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(LinkStateBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      unawaited(_subscription?.cancel());
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.session.linkStates.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.session.linkState);
}
