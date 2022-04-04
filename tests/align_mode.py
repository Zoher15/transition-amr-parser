import sys
from transition_amr_parser.io import read_amr
from transition_amr_parser.amr_machine import AMRStateMachine
from transition_amr_parser.gold_subgraph_align import (
    BadAlignModeSample, check_gold_alignment
)
from numpy.random import choice
from collections import defaultdict, Counter
from ipdb import set_trace
# from numpy.random import randint


class RuleAlignments():

    def __init__(self):
        pass

    def reset(self, gold_amr, machine):

        # NOTE: This is a reference and thus will contain changes in the
        # machine
        self.machine = machine
        self.gold_amr = gold_amr

        tokens = list(gold_amr.tokens)
        id_nodes = list(gold_amr.nodes.items())
        nodeid2token = surface_aligner(
            tokens, id_nodes, cache_key=None
        )[0]

        # store rules activating in this position
        self.rules_by_position = defaultdict(list)
        for nid, items in nodeid2token.items():
            for position, _ in items:
                self.rules_by_position[position].append(gold_amr.nodes[nid])

        # store rules activating in future positions and thus can not be an
        # option at this position
        self.future_rules = defaultdict(set)
        for i in range(len(gold_amr.tokens)):
            for j in range(i + 1, len(gold_amr.tokens)):
                self.future_rules[i] |= set(self.rules_by_position[j])

    def get_valid_actions(self):
        possible_actions = self.machine.get_valid_actions()
        if self.machine.tok_cursor in self.rules_by_position:
            rule_actions = self.rules_by_position[self.machine.tok_cursor]
            valid_actions = list(set(possible_actions) & set(rule_actions))
        else:
            forbidden_rules = self.future_rules[self.machine.tok_cursor]
            valid_actions = list(set(possible_actions) - forbidden_rules)

        if valid_actions:
            return valid_actions
        else:
            return possible_actions


def main():

    trace = False
    trace_if_error = True
    surface_rules = False

    # read AMR instantiate state machine and rules
    amrs = read_amr(sys.argv[1], generate=True)
    machine = AMRStateMachine()
    if surface_rules:
        from transition_amr_parser.amr_aligner import surface_aligner
        rules = RuleAlignments()

    # stats to compute Smatch
    num_tries = 0
    num_hits = 0
    num_gold = 0

    # rejection stats
    rejection_index_count = Counter()
    rejection_reason_count = Counter()
    amr_size_by_id = dict()

    # random_index = randint(1000)

    # loop over all AMRs, return basic alignment
    aligned_penman = []
    for index, amr in enumerate(amrs):

        # if index in [543, 1393, 1435, 1615, 1761]:
        #   continue

        # if amr.penman.metadata['id'] != 'DF-200-192410-470_9050.3':
        #    continue

        # if index != 543:
        #    continue

        # start the machine in align mode
        machine.reset(amr.tokens, gold_amr=amr)
        # optionally start the alignment rules
        #if surface_rules:
        #    rules.reset(amr, machine)

        # runs machine until completion
        force_exit = False
        while not machine.is_closed and not force_exit:

            if trace:
                print(machine)
                set_trace(context=30)

            try:

                # valid actions
                #if surface_rules:
                #    possible_actions = rules.get_valid_actions()
                #else:
                possible_actions = machine.get_valid_actions()

                # random choice among those options
                action = choice(possible_actions)

                # update machine
                machine.update(action)

            except BadAlignModeSample as exception:

                rejection_index_count.update([amr.penman.metadata['id']])
                rejection_reason_count.update([exception.__str__()])
                if amr.penman.metadata['id'] not in amr_size_by_id:
                    amr_size_by_id[amr.penman.metadata['id']] = \
                        len(machine.gold_amr.nodes)

                if rejection_index_count[amr.penman.metadata['id']] > 10:

                    # exit or trace
                    force_exit = True
                    break
                    # check_gold_alignment(machine, trace=True)

                else:

                    # Alignment failed, re-start machine
                    # start the machine in align mode
                    machine.reset(amr.tokens, gold_amr=amr)
                    # optionally start the alignment rules
                    # if surface_rules:
                    #    rules.reset(amr, machine)

        # sanity check
        if not force_exit:
            gold2dec = machine.align_tracker.get_flat_map(reverse=True)
            dec2gold = {v[0]: k for k, v in gold2dec.items()}

            # sanity check: all nodes and edges there
            missing_nodes = [
                n for n in machine.gold_amr.nodes if n not in gold2dec
            ]
            if missing_nodes and trace_if_error:
                print(machine)
                set_trace(context=30)

            # sanity check: all nodes and edges match
            edges = [
                (dec2gold[e[0]], e[1], dec2gold[e[2]])
                for e in machine.edges if (e[0] in dec2gold and e[2] in dec2gold)
            ]
            missing = set(machine.gold_amr.edges) - set(edges)
            excess = set(edges) - set(machine.gold_amr.edges)
            if bool(missing) and trace_if_error:
                print(machine)
                set_trace(context=30)
            elif bool(excess) and trace_if_error:
                print(machine)
                set_trace(context=30)

            # edges
            num_tries += len(machine.edges)
            num_hits += len(machine.edges) - len(missing)
            num_gold += len(machine.gold_amr.edges)

            aligned_penman.append(machine.get_annotation())

    precision = num_hits / num_tries
    recall = num_hits / num_gold
    fscore = 2 * (precision * recall) / (precision + recall)
    print(precision, recall, fscore)
    set_trace(context=30)
    print()


if __name__ == '__main__':
    main()
