import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/agents/sub_agent.dart';
import 'package:mewhub/agents/sub_agent_runner.dart';
import 'package:mewhub/agents/team_board.dart';

void main() {
  final agents = [SubAgent(name: '甲'), SubAgent(name: '乙'), SubAgent(name: '丙')];

  group('parseAssignments', () {
    test('自动编号，依赖按顺序保留', () {
      final r = parseAssignments([
        {'agent': '甲', 'task': '取数'},
        {
          'agent': '乙',
          'task': '审查',
          'depends_on': ['t1'],
        },
        {
          'agent': '丙',
          'task': '出方案',
          'depends_on': ['t1', 't2'],
        },
      ], agents);
      expect(r.problems, isEmpty);
      expect([for (final t in r.tasks) t.id], ['t1', 't2', 't3']);
      expect(r.tasks[1].dependsOn, ['t1']);
      expect(r.tasks[2].dependsOn, ['t1', 't2']);
    });

    test('老写法 wait_for_others 转成依赖前面全部任务', () {
      final r = parseAssignments([
        {'agent': '甲', 'task': 'a'},
        {'agent': '乙', 'task': 'b'},
        {'agent': '丙', 'task': 'c', 'wait_for_others': true},
      ], agents);
      expect(r.tasks.last.dependsOn, ['t1', 't2']);
    });

    test('未知智能体、空任务被剔除并记录', () {
      final r = parseAssignments([
        {'agent': '不存在', 'task': 'x'},
        {'agent': '甲', 'task': '  '},
        {'agent': '乙', 'task': '有效'},
      ], agents);
      expect(r.tasks.length, 1);
      expect(r.tasks.first.agentName, '乙');
      expect(r.problems.length, 2);
    });

    test('依赖不存在会报，但任务本身仍保留', () {
      final r = parseAssignments([
        {
          'agent': '甲',
          'task': 'a',
          'depends_on': ['t9'],
        },
      ], agents);
      expect(r.tasks.length, 1);
      expect(r.problems.any((p) => p.contains('t9')), isTrue);
    });

    test('依赖只能引用前面的任务', () {
      final r = parseAssignments([
        {
          'agent': '甲',
          'task': 'a',
          'task_id': 't1',
          'depends_on': ['t2'],
        },
        {'agent': '乙', 'task': 'b', 'task_id': 't2'},
      ], agents);
      // t1 排在最前面，却依赖了排在它后面的 t2
      expect(r.problems.any((p) => p.contains('排在它后面')), isTrue);
    });

    test('knownIds 里的依赖不参与顺序校验', () {
      final r = parseAssignments(
        [
          {
            'agent': '甲',
            'task': 'a',
            'task_id': 't7',
            'depends_on': ['t1'],
          },
        ],
        agents,
        knownIds: {'t1'},
      );
      expect(r.problems, isEmpty);
    });

    test('超过上限会截断并提示', () {
      final rows = [
        for (var i = 0; i < 12; i++) {'agent': '甲', 'task': '任务 $i'},
      ];
      final r = parseAssignments(rows, agents, maxTasks: 8);
      expect(r.tasks.length, 8);
      expect(r.problems.any((p) => p.contains('上限')), isTrue);
    });
  });

  group('TeamBoard', () {
    test('briefFor 只带已完成前置的产出', () {
      final board = TeamBoard(
        title: 'x',
        tasks: [
          TeamTask(id: 't1', agentName: '甲', task: 'a'),
          TeamTask(id: 't2', agentName: '乙', task: 'b', dependsOn: ['t1']),
        ],
      );
      expect(board.briefFor(board.tasks[1]), isEmpty);
      board.tasks[0]
        ..status = TeamTaskStatus.done
        ..result = SubAgentResult(agent: '甲', task: 'a', output: '取到 300274 日线 640 根');
      final brief = board.briefFor(board.tasks[1]);
      expect(brief, contains('t1'));
      expect(brief, contains('300274'));
    });

    test('briefFor 遵守单任务与总量预算', () {
      final big = 'x' * 4000;
      final board = TeamBoard(
        title: 'x',
        tasks: [
          TeamTask(id: 't1', agentName: '甲', task: 'a'),
          TeamTask(id: 't2', agentName: '甲', task: 'a'),
          TeamTask(id: 't3', agentName: '甲', task: 'a'),
          TeamTask(id: 't4', agentName: '乙', task: 'b', dependsOn: ['t1', 't2', 't3']),
        ],
      );
      for (final t in board.tasks.take(3)) {
        t
          ..status = TeamTaskStatus.done
          ..result = SubAgentResult(agent: '甲', task: 'a', output: big);
      }
      final brief = board.briefFor(board.tasks[3]);
      expect(brief.length, lessThanOrEqualTo(dependencyResultBudget + dependencyResultPerTaskLimit));
      // 每条最多 2500，总量 8000 → 至少带进去 3 条
      expect(brief.split('【t').length - 1, 3);
    });

    test('toJson 统计各状态数量', () {
      final board = TeamBoard(
        title: 'x',
        tasks: [
          TeamTask(id: 't1', agentName: '甲', task: 'a')..status = TeamTaskStatus.done,
          TeamTask(id: 't2', agentName: '甲', task: 'a')..status = TeamTaskStatus.failed,
          TeamTask(id: 't3', agentName: '甲', task: 'a')..status = TeamTaskStatus.skipped,
          TeamTask(id: 't4', agentName: '甲', task: 'a'),
        ],
      );
      final j = board.toJson();
      expect(j['done'], 1);
      expect(j['failed'], 1);
      expect(j['skipped'], 1);
      expect(j['closed'], isFalse);
    });
  });

  group('子智能体协作工具', () {
    test('协作工具名与排除集合对得上', () {
      expect(askMainToolName, 'ask_main_agent');
      expect(requestCapabilityToolName, 'request_capability');
      expect(askPeerToolName, 'ask_peer');
    });

    test('只读黑名单覆盖工作区写操作', () {
      expect(readOnlyBlockedTools, contains('workspace_write_file'));
      expect(readOnlyBlockedTools, contains('workspace_edit_file'));
      expect(readOnlyBlockedTools, contains('chart_annotate'));
    });

    test('内置里非只读的条目能写、只读的不能', () {
      final byName = {for (final a in builtinSubAgents) a.name: a};
      expect(byName['行情侦察']!.readOnly, isFalse);
      expect(byName['资料研究']!.readOnly, isFalse);
      expect(byName['结构审查']!.readOnly, isTrue);
      expect(byName['数据核验']!.readOnly, isTrue);
      expect(byName['图文标注']!.readOnly, isFalse);
    });
  });
}
