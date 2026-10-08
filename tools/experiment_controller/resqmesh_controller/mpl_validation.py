"""Conservative timer replay checks. Missing evidence is never manufactured PASS."""
from collections import defaultdict
from .mpl_config import SEMANTICS


def _state(value):
    """Decode the existing canonical state identity, not a transmitter identity."""
    if not isinstance(value, str):
        return None
    try:
        parts = tuple(int(v) for v in value.split(':'))
    except ValueError:
        return None
    if (len(parts) != 5 or not 0 < parts[0] <= 0xffffffff or parts[1] < 0 or
            parts[2] not in (0, 1, 2) or parts[3] not in (0, 1) or parts[4] not in (0, 1)):
        return None
    return parts


def _inventory(event):
    value = event.get('inventory')
    # Older Dart diagnostics used a pipe-separated canonical inventory.
    if isinstance(value, str):
        value = value.split('|') if value else []
    if not isinstance(value, list):
        return None
    states = [_state(v) for v in value]
    if any(s is None for s in states) or len({s[0] for s in states}) != len(states):
        return None
    return states


def _covers(peer, local):
    priority = {1: 0, 0: 1, 2: 2}
    return peer[0] == local[0] and (peer[1] > local[1] or
        (peer[1] == local[1] and (peer == local or peer[3] == 1 or
         (local[3] == 0 and priority[peer[2]] > priority[local[2]]))))


def checks(samples, parameters):
    result = []

    def put(name, evidence, bad, sufficient=True):
        result.append((name, bool(evidence) and sufficient and not bad, bool(bad),
                       f"Bukti {len(evidence)} event; kontradiksi {len(bad)}"))

    events = [e for e in samples if str(e.get('event_type', '')).startswith('MPL_')]
    def complete(e):
        return (e.get('timer_kind') in ('data', 'control') and e.get('timer_key') is not None and
                all(type(e.get(k)) is int for k in ('generation', 'interval_ms',
                    'interval_started_at_monotonic_ms','transmit_at_monotonic_ms',
                    'interval_end_at_monotonic_ms','consistency_count','k','expiration_count')))
    timer_events = [e for e in events if e.get('event_type') in {
        'MPL_INTERVAL_STARTED','MPL_INTERVAL_ENDED','MPL_C_INCREMENT','MPL_TX_ALLOWED',
        'MPL_TX_SUPPRESSED','MPL_TX_OPPORTUNITY','MPL_NATIVE_STARTED','MPL_TIMER_STOPPED'}]
    full = all(complete(e) for e in timer_events)
    parameter_full = full
    parameter_bad = []
    for e in timer_events:
        if not complete(e):
            continue
        kind = e['timer_kind']
        expected_k = parameters.get(f'mpl_{kind}_k')
        expected_limit = parameters.get(f'mpl_{kind}_expirations')
        if type(expected_k) is not int or type(expected_limit) is not int:
            parameter_full = False
            continue
        if e['k'] != expected_k:
            parameter_bad.append(e)
        if type(e.get('expiration_limit')) is not int:
            parameter_full = False
        elif e['expiration_limit'] != expected_limit:
            parameter_bad.append(e)
    put('MPL_PARAMETERS_MATCH', timer_events, parameter_bad, parameter_full)
    starts = [e for e in timer_events if e['event_type']=='MPL_INTERVAL_STARTED' and complete(e)]
    bad = []
    for e in starts:
        i, s, t, end = (e[k] for k in ('interval_ms','interval_started_at_monotonic_ms',
            'transmit_at_monotonic_ms','interval_end_at_monotonic_ms'))
        # ESP millis is uint32; subtraction must be wrap-safe.
        delta = (t-s) & 0xffffffff
        imin, imax = (parameters.get(f"mpl_{e['timer_kind']}_{b}_ms") for b in ('imin','imax'))
        if (imin is None or imax is None):
            full = False; continue
        ratio = i // imin if imin > 0 else 0
        if (imin <= 0 or not imin <= i <= imax or i % imin or not ratio or ratio & (ratio-1) or
                not i//2 <= delta < i or ((end-s)&0xffffffff)!=i or e['consistency_count']!=0):
            bad.append(e)
    put('MPL_LISTEN_ONLY_AND_BOUNDS', starts, bad, full)
    decisions = [e for e in timer_events if e['event_type'] in ('MPL_TX_ALLOWED','MPL_TX_SUPPRESSED') and complete(e)]
    bad = [e for e in decisions if e['k']<1 or e['consistency_count']<0 or
           (type(parameters.get(f"mpl_{e['timer_kind']}_k")) is int and
            e['k']!=parameters[f"mpl_{e['timer_kind']}_k"]) or
           (e['event_type']=='MPL_TX_SUPPRESSED' and e['consistency_count']<e['k']) or
           (e['event_type']=='MPL_TX_ALLOWED' and e['consistency_count']>=e['k'] and e.get('override') is not True)]
    put('MPL_C_K_DECISIONS', decisions, bad, full and all(
        type(parameters.get(f"mpl_{e['timer_kind']}_k")) is int for e in decisions))
    grouped = defaultdict(list)
    for e in timer_events:
        if complete(e): grouped[(e.get('node_id'),e['timer_kind'],e['timer_key'])].append(e)
    bad, accounted = [], []
    outcomes_full = full
    for stream in grouped.values():
        by_gen=defaultdict(list)
        for e in stream: by_gen[e['generation']].append(e)
        for group in by_gen.values():
            endings=[e for e in group if e['event_type']=='MPL_INTERVAL_ENDED']
            accounted.extend(endings)
            for end in endings:
                outcomes=[e for e in events if e.get('node_id')==end.get('node_id') and
                          e.get('timer_kind')==end['timer_kind'] and e.get('timer_key')==end['timer_key'] and
                          e.get('generation')==end['generation'] and e.get('event_type') in
                          ('MPL_TX_ALLOWED','MPL_TX_SUPPRESSED','MPL_TX_MISSED')]
                if not outcomes: outcomes_full = False
    put('MPL_OPPORTUNITY_ACCOUNTING', accounted, bad, outcomes_full)
    stopped=[e for e in events if e.get('event_type')=='MPL_TIMER_STOPPED']
    bad=[e for e in stopped if e.get('buffer_retained') is not True or
         (type(e.get('expiration_count')) is int and
          e['expiration_count']!=parameters.get(f"mpl_{e.get('timer_kind')}_expirations"))]
    put('MPL_EXPIRATION_RETAINS_BUFFER', stopped, bad, all(complete(e) for e in stopped))
    native=[e for e in timer_events if e['event_type']=='MPL_NATIVE_STARTED' and complete(e)]
    bad=[e for e in native if not ((e.get('monotonic_ms',e.get('elapsed_realtime_ms',-1))-
          e['interval_started_at_monotonic_ms'])&0xffffffff) in range(
          (e['transmit_at_monotonic_ms']-e['interval_started_at_monotonic_ms'])&0xffffffff,e['interval_ms'])]
    put('MPL_NATIVE_INSIDE_INTERVAL', native, bad, full)
    repairs=[e for e in events if e.get('event_type')=='MPL_REPAIR_COMPLETED']
    sufficient=all(all(type(e.get(k)) is int for k in ('peer_id','peer_boot','budget_used','budget_limit','episode_until')) for e in repairs)
    bad=[e for e in repairs if type(e.get('budget_used')) is int and
         not 1<=e['budget_used']<=parameters.get('mpl_repair_budget',0)]
    by_episode = defaultdict(list)
    for e in repairs:
        if all(type(e.get(k)) is int for k in ('peer_id','peer_boot','episode_until','budget_used','budget_limit')):
            by_episode[(e.get('node_id'),e.get('timer_key'),e['peer_id'],e['peer_boot'],e['episode_until'])].append(e)
    for episode in by_episode.values():
        limit = parameters.get('mpl_repair_budget',0)
        if len(episode)>limit or any(e['budget_limit']!=limit for e in episode):
            bad.extend(episode)
        for previous,current in zip(episode,episode[1:]):
            if current['budget_used']!=previous['budget_used']+1:
                bad.append(current)
    put('MPL_REPAIR_BOUNDS', repairs, bad, sufficient)
    ended=[e for e in timer_events if e['event_type']=='MPL_INTERVAL_ENDED' and complete(e)]
    bad=[]
    chain_full=full
    for end in ended:
        initial=next((s for s in starts if all(s.get(k)==end.get(k) for k in
                     ('node_id','timer_kind','timer_key','generation'))),None)
        if initial is None:
            chain_full=False
        elif end['expiration_count']!=initial['expiration_count']+1:
            bad.append(end)
        successor=next((s for s in starts if all(s.get(k)==end.get(k) for k in
                        ('node_id','timer_kind','timer_key')) and s['generation']==end['generation']+1
                       and s['interval_started_at_monotonic_ms']==end['interval_end_at_monotonic_ms']),None)
        limit=parameters.get(f"mpl_{end['timer_kind']}_expirations")
        imax=parameters.get(f"mpl_{end['timer_kind']}_imax_ms")
        same=lambda e: all(e.get(k)==end.get(k) for k in ('node_id','timer_kind','timer_key','generation'))
        stops=[e for e in stopped if same(e) and complete(e)]
        reset_proven = successor is not None and successor['expiration_count']==0 and any(
            e.get('event_type')=='MPL_TIMER_RESTARTED' and complete(e) and all(
                e.get(k)==successor.get(k) for k in ('node_id','timer_kind','timer_key','generation',
                    'interval_started_at_monotonic_ms','interval_ms','expiration_count')) for e in events)
        if type(limit) is not int or type(imax) is not int:
            chain_full=False
        elif end['expiration_count'] == limit:
            if not stops:
                chain_full=False
            if any(type(e.get('active')) is not bool or e.get('reason') is None for e in stops):
                chain_full=False
            if (successor is not None and not reset_proven) or any(e['expiration_count']!=limit or e.get('active') is True
                    or (e.get('reason') is not None and e['reason']!='EXPIRATION_LIMIT') for e in stops):
                bad.append(end)
        elif end['expiration_count'] > limit or stops:
            bad.append(end)
        elif successor is None:
            chain_full=False
        elif successor['expiration_count']==0:
            if successor['interval_ms']!=parameters.get(f"mpl_{end['timer_kind']}_imin_ms"):
                bad.append(successor)
            elif not reset_proven:
                chain_full=False
        elif (successor['expiration_count']!=end['expiration_count'] or
              successor['interval_ms']!=min(end['interval_ms']*2,imax)):
            bad.append(successor)
    put('MPL_EXPIRATION_AND_DOUBLING',ended,bad,chain_full)
    rx=[e for e in events if e['event_type']=='MPL_RX_CLASSIFIED']
    required=('peer_id','peer_boot','physical_received_monotonic_ms','monotonic_ms')
    rx_full=all(all(type(e.get(k)) is int for k in required) for e in rx)
    bad=[e for e in rx if all(type(e.get(k)) is int for k in required) and
         ((e['monotonic_ms']-e['physical_received_monotonic_ms'])&0xffffffff)>parameters.get('mpl_freshness_ms',0)]
    put('MPL_PHYSICAL_FRESHNESS',rx,bad,rx_full)
    resets=[e for e in events if e['event_type']=='MPL_REPAIR_RESET']
    reset_full=all(all(type(e.get(k)) is int for k in ('peer_id','peer_boot','episode_until','monotonic_ms')) for e in resets)
    bad=[]
    grouped_resets=defaultdict(list)
    for e in resets:
        if not all(type(e.get(k)) is int for k in ('peer_id','peer_boot','episode_until','monotonic_ms')):
            continue
        grouped_resets[(e.get('node_id'),e.get('timer_key'),e['peer_id'],e['peer_boot'],e['episode_until'])].append(e)
    for group in grouped_resets.values():
        if len(group)>parameters.get('mpl_repair_budget',0): bad.extend(group)
        for previous,current in zip(group,group[1:]):
            if ((current['monotonic_ms']-previous['monotonic_ms'])&0xffffffff)<parameters.get('mpl_repair_cooldown_ms',0): bad.append(current)
    put('MPL_REPAIR_RESET_STORM',resets,bad,reset_full)
    # Require peer-specific RX evidence; another peer cannot validate an override.
    pending=[e for e in events if e['event_type']=='MPL_REPAIR_PENDING']
    bad=[]; repair_full=rx_full
    for repair in pending:
        evidence=[e for e in rx if e.get('node_id')==repair.get('node_id') and
                  e.get('peer_id')==repair.get('peer_id') and e.get('peer_boot')==repair.get('peer_boot') and
                  e.get('monotonic_ms')==repair.get('monotonic_ms') and
                  (repair.get('transmission_sequence') is None or
                   e.get('transmission_sequence')==repair['transmission_sequence'])]
        local=_state(repair.get('timer_key'))
        if len(evidence)!=1 or local is None:
            repair_full=False
            continue
        proof=evidence[0]
        if proof.get('snapshot_complete') is False or proof.get('frame_type')=='data':
            bad.append(repair)
        states=_inventory(proof)
        if (proof.get('snapshot_complete') is not True or proof.get('frame_type')!='status'
                or states is None):
            repair_full=False
            continue
        if any(_covers(peer,local) for peer in states):
            bad.append(repair)
    put('MPL_REPAIR_PEER_EVIDENCE',pending,bad,repair_full)
    provenance=[e for e in events if e.get('scheduler_semantics') is not None]
    put('MPL_SEMANTICS_PROVENANCE', provenance,
        [e for e in provenance if e['scheduler_semantics']!=SEMANTICS],len(provenance)==len(events))
    return result
