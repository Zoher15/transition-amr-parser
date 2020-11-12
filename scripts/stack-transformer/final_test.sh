set -o errexit 
set -o pipefail
# setup environment
. set_environment.sh
# Argument handling
config=$1
checkpoint=$2
results_folder=$3
[ -z "$config" ] && \
    echo -e "\n$0 <config> <model_checkpoint> [<results_folder>]\n" && \
    exit 1
[ -z "$checkpoint" ] && \
    echo -e "\n$0 <config> <model_checkpoint> [<results_folder>] \n" && \
    exit 1
[ -z "$results_folder" ] && \
    results_folder=""
set -o nounset 

# Load config
. "$config"

# If not provided as an argument, use the folder where the checkpoint is
# contained to store the results
if [ "$results_folder" == "" ];then
    # fix for ensembles
    single_checkpoint=$(echo $checkpoint | sed 's@\.pt:.*@@')
    results_folder=$(dirname $single_checkpoint)/$TEST_TAG/
fi
mkdir -p $results_folder

# to profile decoder
# 1. pip install line_profiler
# 2. decorate target function with @profile
# 3. call instead of fairseq-generate
# 4. then you can consult details with 
# python -m line_profiler generate.py.lprof
#test_command="kernprof -o generate.lprof -l fairseq/generate.py"
test_command=fairseq-generate

if [ "$TASK_TAG" == "AMR" ] ; then

    if [ -n "${ENTITY_RULES:-}" ] && [ -f "$ENTITY_RULES" ] ; then
	    echo "using given entity rules"
    else
	    echo "reading entity rules from oracle"
	    ENTITY_RULES=$ORACLE_FOLDER/entity_rules.json
    fi

    # decode 
    echo "$test_command $FAIRSEQ_GENERATE_ARGS --path $checkpoint
        --results-path $results_folder/test --entity-rules $ENTITY_RULES"
    
    $test_command $FAIRSEQ_GENERATE_ARGS \
        --path $checkpoint \
        --results-path $results_folder/test \
        --entity-rules $ENTITY_RULES

else

    # decode 
    echo "$test_command $FAIRSEQ_GENERATE_ARGS --path $checkpoint
        --results-path $results_folder/test"

    $test_command $FAIRSEQ_GENERATE_ARGS \
        --path $checkpoint \
        --results-path $results_folder/test
    
fi

model_folder=$(dirname $checkpoint)

# Create oracle data
if [ "$TASK_TAG" == "dep-parsing" ];then

    # Create the AMR from the model obtained actions
    python scripts/dep_parsing_score.py \
        --in-tokens $ORACLE_FOLDER/test.en \
        --in-actions $results_folder/test.actions \
        --in-gold-actions $ORACLE_FOLDER/test.actions \
        > $results_folder/test.las
    cat $results_folder/test.las

elif [ "$TASK_TAG" == "AMR" ];then

    # Create the AMR from the model obtained actions
    amr-fake-parse \
    	--entity-rules $ENTITY_RULES \
        --in-sentences $ORACLE_FOLDER/test.en \
        --in-actions $results_folder/test.actions \
        --out-amr $results_folder/test.amr \

    if [ "$WIKI_TEST" == "" ];then

        # Smatch evaluation without wiki
        smatch.py \
             --significant 4  \
             -f $AMR_TEST_FILE \
             $results_folder/test.amr \
             -r 10 \
             > $results_folder/test.smatch
        
        # plot score
        cat $results_folder/test.smatch

    else

        # Smatch evaluation with wiki

        # add wiki
#        python scripts/add_wiki.py \
#            $results_folder/test.amr $WIKI_TEST \
#            > $results_folder/test.wiki.amr
    
        python scripts/retyper.py \
            --inputfile ${results_folder}/test.amr \
            --outputfile ${results_folder}.test.wiki.amr \
            --skipretyper \
            --wikify \
#            --blinkmodels <<pathtoblinkmodels>> \
            --blinkcachepath $BLINK_CACHE_PATH \
            --blinkthreshold 0.0

        # Compute score
        smatch.py \
             --significant 4  \
             -f $AMR_TEST_FILE_WIKI \
             $results_folder/test.wiki.amr \
             -r 10 \
             > $results_folder/test.wiki.smatch
    
        cat $results_folder/test.wiki.smatch

    fi

elif [ "$TASK_TAG" == "NER" ];then

    # play actions to create annotations
    python play.py \
        --in-tokens $ORACLE_FOLDER/test.en \
        --in-actions $results_folder/test.actions \
        --machine-type NER \
        --out-annotations-folder $results_folder/ \
        --basename test
    
    # measure performance
    python bio_tags/metrics.py \
        --in-annotations $results_folder/test.dat \
        --in-reference-annotations $NER_TEST_FILE \
        --out-score $results_folder/test.f-measure

elif [ "$TASK_TAG" == "NER+AMR" ];then

    # AMR scores
    python play.py \
        --in-tokens $ORACLE_FOLDER/test.en \
        --in-actions $results_folder/test.actions \
        --in-mixing-indices $ORACLE_FOLDER/test.mixing_indices \
        --out-annotations-folder $results_folder/ \
        --basename test \
    
    # compute F-measure for NER
    python bio_tags/metrics.py \
        --in-annotations $results_folder/test.dat \
        --in-reference-annotations $NER_TEST_FILE \
        --out-score $results_folder/test.f-measure
    cat $results_folder/test.f-measure

    # compute smatch for AMR
    smatch.py \
     --significant 4  \
         -f $AMR_TEST_FILE \
         $results_folder/test.amr \
     -r 10 \
         > $results_folder/test.smatch
    cat $results_folder/test.smatch

fi
