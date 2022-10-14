#!/bin/bash
source test_tipc/common_func.sh

FILENAME=$1
# MODE be one of ['lite_train_lite_infer' 'lite_train_whole_infer' 'whole_train_whole_infer', 'whole_infer']
MODE=$2

dataline=$(awk 'NR>=1{print}'  $FILENAME)

# parser params
IFS=$'\n'
lines=(${dataline})

# The training params
model_name=$(func_parser_value "${lines[1]}")
python=$(func_parser_value "${lines[2]}")
gpu_list=$(func_parser_value "${lines[3]}")
train_use_gpu_key=$(func_parser_key "${lines[4]}")
train_use_gpu_value=$(func_parser_value "${lines[4]}")
autocast_list=$(func_parser_value "${lines[5]}")
autocast_key=$(func_parser_key "${lines[5]}")
epoch_key=$(func_parser_key "${lines[6]}")
epoch_num=$(func_parser_params "${lines[6]}")
save_model_key=$(func_parser_key "${lines[7]}")
train_batch_key=$(func_parser_key "${lines[8]}")
train_batch_value=$(func_parser_params "${lines[8]}")
pretrain_model_key=$(func_parser_key "${lines[9]}")
pretrain_model_value=$(func_parser_value "${lines[9]}")
train_model_name=$(func_parser_value "${lines[10]}")
train_infer_img_dir=$(func_parser_value "${lines[11]}")
train_param_key1=$(func_parser_key "${lines[12]}")
train_param_value1=$(func_parser_value "${lines[12]}")

trainer_list=$(func_parser_value "${lines[14]}")
trainer_norm=$(func_parser_key "${lines[15]}")
norm_trainer=$(func_parser_value "${lines[15]}")
pact_key=$(func_parser_key "${lines[16]}")
pact_trainer=$(func_parser_value "${lines[16]}")
fpgm_key=$(func_parser_key "${lines[17]}")
fpgm_trainer=$(func_parser_value "${lines[17]}")
distill_key=$(func_parser_key "${lines[18]}")
distill_trainer=$(func_parser_value "${lines[18]}")
trainer_key1=$(func_parser_key "${lines[19]}")
trainer_value1=$(func_parser_value "${lines[19]}")
trainer_key2=$(func_parser_key "${lines[20]}")
trainer_value2=$(func_parser_value "${lines[20]}")

eval_py=$(func_parser_value "${lines[23]}")
eval_key1=$(func_parser_key "${lines[24]}")
eval_value1=$(func_parser_value "${lines[24]}")

save_infer_key=$(func_parser_key "${lines[27]}")
export_weight=$(func_parser_key "${lines[28]}")
norm_export=$(func_parser_value "${lines[29]}")
pact_export=$(func_parser_value "${lines[30]}")
fpgm_export=$(func_parser_value "${lines[31]}")
distill_export=$(func_parser_value "${lines[32]}")
export_key1=$(func_parser_key "${lines[33]}")
export_value1=$(func_parser_value "${lines[33]}")
export_key2=$(func_parser_key "${lines[34]}")
export_value2=$(func_parser_value "${lines[34]}")
inference_dir=$(func_parser_value "${lines[35]}")

# parser inference model
infer_model_dir_list=$(func_parser_value "${lines[36]}")
infer_export_list=$(func_parser_value "${lines[37]}")
infer_is_quant=$(func_parser_value "${lines[38]}")
# parser inference
inference_py=$(func_parser_value "${lines[39]}")
use_gpu_key=$(func_parser_key "${lines[40]}")
use_gpu_list=$(func_parser_value "${lines[40]}")
use_mkldnn_key=$(func_parser_key "${lines[41]}")
use_mkldnn_list=$(func_parser_value "${lines[41]}")
cpu_threads_key=$(func_parser_key "${lines[42]}")
cpu_threads_list=$(func_parser_value "${lines[42]}")
batch_size_key=$(func_parser_key "${lines[43]}")
batch_size_list=$(func_parser_value "${lines[43]}")
use_trt_key=$(func_parser_key "${lines[44]}")
use_trt_list=$(func_parser_value "${lines[44]}")
precision_key=$(func_parser_key "${lines[45]}")
precision_list=$(func_parser_value "${lines[45]}")
infer_model_key=$(func_parser_key "${lines[46]}")
image_dir_key=$(func_parser_key "${lines[47]}")
infer_img_dir=$(func_parser_value "${lines[47]}")
save_log_key=$(func_parser_key "${lines[48]}")
benchmark_key=$(func_parser_key "${lines[49]}")
benchmark_value=$(func_parser_value "${lines[49]}")
infer_key1=$(func_parser_key "${lines[50]}")
infer_value1=$(func_parser_value "${lines[50]}")
infer_key2=$(func_parser_key "${lines[51]}")	##
infer_value2=$(func_parser_value "${lines[51]}") ##

LOG_PATH="./test_tipc/output/${model_name}/${MODE}"  ##
mkdir -p ${LOG_PATH}
status_log="${LOG_PATH}/results_python.log"
echo "------------------------ ${MODE} ------------------------" >> $status_log

# Parse extra args
parse_extra_args "${lines[@]}"
for params in ${extra_args[*]}; do
    IFS=":"
    arr=(${params})
    key=${arr[0]}
    value=${arr[1]}
    if [ "${key}" = 'log_iters' ]; then
        log_iters="${value}"
    elif [ "${key}" = "repeats" ]; then
        repeats="${value}"
    fi
done

if [ "${MODE}" = 'benchmark_train' ];then
    if [ "${autocast_key}" = 'Global.auto_cast' ];then
        echo 'Replcace ${autocast_key}'"('${autocast_key}') with '--precision'"
        autocast_key="--precision"
    fi
fi

function func_inference(){
    IFS='|'
    _python=$1
    _script=$2
    _model_dir="$3/deploy.yaml"
    _log_path=$4
    _img_dir=$5
    _flag_quant=$6
    _gpu=$7
    # inference
    for use_gpu in ${use_gpu_list[*]}; do
        if [ ${use_gpu} = "False" ] || [ ${use_gpu} = "cpu" ]; then
            for use_mkldnn in ${use_mkldnn_list[*]}; do
                if [ ${use_mkldnn} = "False" ] && [ ${_flag_quant} = "True" ]; then
                    continue
                fi
                for threads in ${cpu_threads_list[*]}; do
                    for batch_size in ${batch_size_list[*]}; do
                        for precision in ${precision_list[*]}; do
                            if [ ${use_mkldnn} = "False" ] && [ ${precision} = "fp16" ]; then
                                continue
                            fi # skip when enable fp16 but disable mkldnn
                            if [ ${_flag_quant} = "True" ] && [ ${precision} != "int8" ]; then
                                continue
                            fi # skip when quant model inference but precision is not int8
                            if [ ${_flag_quant} = "False" ] && [ ${precision} != "fp32" ]; then ##
                                continue
                            fi # skip when not quant model inference and precision is not fp32

                            set_precision=$(func_set_params "${precision_key}" "${precision}")

                            _save_log_path="${_log_path}/python_infer_cpu_gpu_${gpu}_usemkldnn_${use_mkldnn}_threads_${threads}_precision_${precision}_batchsize_${batch_size}.log"
                            infer_value1="${_log_path}/python_infer_cpu_usemkldnn_${use_mkldnn}_threads_${threads}_precision_${precision}_batchsize_${batch_size}_results"
                            set_infer_data=$(func_set_params "${image_dir_key}" "${_img_dir}")
                            set_benchmark=$(func_set_params "${benchmark_key}" "${benchmark_value}")
                            set_batchsize=$(func_set_params "${batch_size_key}" "${batch_size}")
                            set_cpu_threads=$(func_set_params "${cpu_threads_key}" "${threads}")
                            set_model_dir=$(func_set_params "${infer_model_key}" "${_model_dir}")
                            set_infer_params1=$(func_set_params "${infer_key1}" "${infer_value1}")  ##
                            set_infer_params2=$(func_set_params "${infer_key2}" "${infer_value2}")  ##
                            command="${_python} ${_script} ${use_gpu_key}=${use_gpu} ${use_mkldnn_key}=${use_mkldnn} ${set_cpu_threads} ${set_model_dir} ${set_batchsize} ${set_infer_data} ${set_benchmark} ${set_precision} ${set_infer_params1} ${set_infer_params2} > ${_save_log_path} 2>&1 " ##
                            echo $command
                            eval $command
                            last_status=${PIPESTATUS[0]}
                            eval "cat ${_save_log_path}"
                            status_check $last_status "${command}" "${status_log}" "${model_name}" "${_save_log_path}"
                        done
                    done
                done
            done
        elif [ ${use_gpu} = "True" ] || [ ${use_gpu} = "gpu" ]; then
            for use_trt in ${use_trt_list[*]}; do
                for precision in ${precision_list[*]}; do
                    if [[ ${_flag_quant} = "False" ]] && [[ ${precision} =~ "int8" ]]; then
                        continue
                    fi
                    if [[ ${precision} =~ "fp16" || ${precision} =~ "int8" ]] && [ ${use_trt} = "False" ]; then
                        continue
                    fi
                    if [[ ${use_trt} = "False" || ${precision} =~ "int8" ]] && [ ${_flag_quant} = "True" ]; then
                        continue
                    fi
                    for batch_size in ${batch_size_list[*]}; do
                        _save_log_path="${_log_path}/python_infer_gpu_gpu_${gpu}_usetrt_${use_trt}_precision_${precision}_batchsize_${batch_size}.log"
                        infer_value1="${_log_path}/python_infer_gpu_usetrt_${use_trt}_precision_${precision}_batchsize_${batch_size}_results"
                        set_infer_data=$(func_set_params "${image_dir_key}" "${_img_dir}")
                        set_benchmark=$(func_set_params "${benchmark_key}" "${benchmark_value}")
                        set_batchsize=$(func_set_params "${batch_size_key}" "${batch_size}")
                        set_tensorrt=$(func_set_params "${use_trt_key}" "${use_trt}")
                        set_precision=$(func_set_params "${precision_key}" "${precision}")
                        set_model_dir=$(func_set_params "${infer_model_key}" "${_model_dir}")
                        set_infer_params1=$(func_set_params "${infer_key1}" "${infer_value1}")  ##
                        set_infer_params2=$(func_set_params "${infer_key2}" "${infer_value2}")  ##
                        command="${_python} ${_script} ${use_gpu_key}=${use_gpu} ${set_tensorrt} ${set_precision} ${set_model_dir} ${set_batchsize} ${set_infer_data} ${set_benchmark} ${set_infer_params2} > ${_save_log_path} 2>&1 " ##
                        echo $command
                        eval $command
                        last_status=${PIPESTATUS[0]}
                        eval "cat ${_save_log_path}"
                        status_check $last_status "${command}" "${status_log}" "${model_name}" "${_save_log_path}"

                    done
                done
            done
        else
            echo "Does not support hardware other than CPU and GPU Currently!"
        fi
    done
}

if [ ${MODE} = "whole_infer" ] || [ ${MODE} = "klquant_whole_infer" ]; then
    GPUID=$3
    if [ ${#GPUID} -le 0 ];then
        env=" "
    else
        env="export CUDA_VISIBLE_DEVICES=${GPUID}"
    fi
    # set CUDA_VISIBLE_DEVICES
    eval $env
    export Count=0
    gpu=0
    IFS="|"
    infer_run_exports=(${infer_export_list})
    infer_quant_flag=(${infer_is_quant})
    for infer_model in ${infer_model_dir_list[*]}; do
        # run export
        if [ ${infer_run_exports[Count]} != "null" ];then
            save_infer_dir=$(dirname $infer_model)
            set_export_weight=$(func_set_params "${export_weight}" "${infer_model}")
            set_save_infer_key=$(func_set_params "${save_infer_key}" "${save_infer_dir}")
            export_cmd="${python} ${infer_run_exports[Count]} ${set_export_weight} ${set_save_infer_key}"
            echo ${infer_run_exports[Count]}
            eval $export_cmd
            status_export=$?
            status_check $status_export "${export_cmd}" "${status_log}" "${model_name}"
        else
            save_infer_dir=${infer_model}
        fi
        #run inference
        is_quant=${infer_quant_flag[Count]}
        if [ ${MODE} = "klquant_infer" ]; then
            is_quant="True"
        fi
        func_inference "${python}" "${inference_py}" "${save_infer_dir}" "${LOG_PATH}" "${infer_img_dir}" ${is_quant} ${gpu}
        Count=$(($Count + 1))
    done
else
    IFS="|"
    export Count=0
    USE_GPU_KEY=(${train_use_gpu_value})
    for gpu in ${gpu_list[*]}; do
        train_use_gpu=${USE_GPU_KEY[Count]}
        Count=$(($Count + 1))
        ips=""
        if [ ${gpu} = "-1" ];then
            env=""
        elif [ ${#gpu} -le 1 ];then
            env="export CUDA_VISIBLE_DEVICES=${gpu}"
            eval ${env}
        elif [ ${#gpu} -le 15 ];then
            IFS=","
            array=(${gpu})
            env="export CUDA_VISIBLE_DEVICES=${array[0]}"
            IFS="|"
        else
            IFS=";"
            array=(${gpu})
            ips=${array[0]}
            gpu=${array[1]}
            IFS="|"
            env=" "
        fi
        for autocast in ${autocast_list[*]}; do
            if [ ${autocast} = "amp" ]; then
                set_amp_config="Global.use_amp=True Global.scale_loss=1024.0 Global.use_dynamic_loss_scaling=True"
            elif [ "${autocast}" = 'fp16' ] && [ "${MODE}" = 'benchmark_train' ];then
                set_amp_config="--amp_level=O2"
            else
                set_amp_config=" "
            fi
            for trainer in ${trainer_list[*]}; do
                flag_quant=False
                if [ ${trainer} = ${pact_key} ]; then
                    run_train=${pact_trainer}
                    run_export=${pact_export}
                    flag_quant=True
                elif [ ${trainer} = "${fpgm_key}" ]; then
                    run_train=${fpgm_trainer}
                    run_export=${fpgm_export}
                elif [ ${trainer} = "${distill_key}" ]; then
                    run_train=${distill_trainer}
                    run_export=${distill_export}
                elif [ ${trainer} = ${trainer_key1} ]; then
                    run_train=${trainer_value1}
                    run_export=${export_value1}
                elif [[ ${trainer} = ${trainer_key2} ]]; then
                    run_train=${trainer_value2}
                    run_export=${export_value2}
                else
                    run_train=${norm_trainer}
                    run_export=${norm_export}
                fi

                if [ ${run_train} = "null" ]; then
                    continue
                fi
                set_autocast=$(func_set_params "${autocast_key}" "${autocast}")
                set_epoch=$(func_set_params "${epoch_key}" "${epoch_num}")
                set_pretrain=$(func_set_params "${pretrain_model_key}" "${pretrain_model_value}")
                set_batchsize=$(func_set_params "${train_batch_key}" "${train_batch_value}")
                set_train_params1=$(func_set_params "${train_param_key1}" "${train_param_value1}")
                set_use_gpu=$(func_set_params "${train_use_gpu_key}" "${train_use_gpu}")
                # if length of ips >= 15, then it is seen as multi-machine
                # 15 is the min length of ips info for multi-machine: 0.0.0.0,0.0.0.0
                if [ ${#ips} -le 15 ];then
                    save_log="${LOG_PATH}/${trainer}_gpus_${gpu}_autocast_${autocast}"
                    nodes=1
                else
                    IFS=","
                    ips_array=(${ips})
                    IFS="|"
                    nodes=${#ips_array[@]}
                    save_log="${LOG_PATH}/${trainer}_gpus_${gpu}_autocast_${autocast}_nodes_${nodes}"
                fi
                log_path="${LOG_PATH}/${trainer}_gpus_${gpu}_autocast_${autocast}_nodes_${nodes}.log"

                # load pretrain from norm training if current trainer is pact or fpgm trainer
                if ([ ${trainer} = ${pact_key} ] || [ ${trainer} = ${fpgm_key} ]) && [ ${nodes} -le 1 ]; then
                    set_pretrain="${load_norm_train_model}"
                fi

                set_save_model=$(func_set_params "${save_model_key}" "${save_log}")
                if [ ${#gpu} -le 2 ];then  # train with cpu or single gpu
                    cmd="${python} ${run_train} ${set_use_gpu}  ${set_save_model} ${set_epoch} ${set_pretrain} ${set_autocast} ${set_batchsize} ${set_train_params1} ${set_amp_config}"
                elif [ ${#ips} -le 15 ];then  # train with multi-gpu
                    cmd="${python} -m paddle.distributed.launch --devices=${gpu} ${run_train} ${set_use_gpu} ${set_save_model} ${set_epoch} ${set_pretrain} ${set_autocast} ${set_batchsize} ${set_train_params1} ${set_amp_config}"
                else     # train with multi-machine
                    cmd="${python} -m paddle.distributed.launch --ips=${ips} --devices=${gpu} ${run_train} ${set_use_gpu} ${set_save_model} ${set_pretrain} ${set_epoch} ${set_autocast} ${set_batchsize} ${set_train_params1} ${set_amp_config}"
                fi
                
                if [ "${MODE}" = 'benchmark_train' ] && [ -n "${log_iters}" ];then
                    cmd="${cmd} --log_iters ${log_iters}"
                fi

                if [ "${MODE}" = 'benchmark_train' ] && [ -n "${repeats}" ];then
                    cmd="${cmd} --repeats ${repeats}"
                fi

                if [ -n "${amp_level}" ];then
                    cmd="${cmd} --amp_level ${amp_level}"
                fi

                echo "$cmd"
                # run train
                run_command "${cmd}" "${log_path}"
                status_check $? "${cmd}" "${status_log}" "${model_name}" "${log_path}"

                if [[ "$cmd" == *'paddle.distributed.launch'* ]]; then
                    cat log/workerlog.0 >> ${log_path} 
                fi
                
                # modify model dir if no eval
                if [ ! -f "${save_log}/${train_model_name}" ]; then
                    train_model_name="iter_${epoch_num}/model.pdparams"
                fi
                set_eval_pretrain=$(func_set_params "${pretrain_model_key}" "${save_log}/${train_model_name}")
                # save norm trained models to set pretrain for pact training and fpgm training
                if [ ${trainer} = ${trainer_norm} ] && [ ${nodes} -le 1 ]; then
                    load_norm_train_model=${set_eval_pretrain}
                fi
                # run eval
                if [ ${eval_py} != "null" ]; then
                    log_path="${LOG_PATH}/${trainer}_gpus_${gpu}_autocast_${autocast}_nodes_${nodes}_eval.log"
                    set_eval_params1=$(func_set_params "${eval_key1}" "${eval_value1}")
                    eval_cmd="${python} ${eval_py} ${set_eval_pretrain} ${set_use_gpu} ${set_eval_params1}"
                    run_command "${eval_cmd}" "${log_path}"
                    status_check $? "${eval_cmd}" "${status_log}" "${model_name}" "${log_path}"
                fi
                # run export model
                if [ ${run_export} != "null" ]; then
                    # run export model
                    log_path="${LOG_PATH}/${trainer}_gpus_${gpu}_autocast_${autocast}_nodes_${nodes}_export.log"
                    save_infer_path="${save_log}"
                    set_export_weight=$(func_set_params "${export_weight}" "${save_log}/${train_model_name}")
                    set_save_infer_key=$(func_set_params "${save_infer_key}" "${save_infer_path}")
                    export_cmd="${python} ${run_export} ${set_export_weight} ${set_save_infer_key}"
                    run_command "${export_cmd}" "${log_path}"
                    status_check $? "${export_cmd}" "${status_log}" "${model_name}" "${log_path}"

                    #run inference
                    eval $env
                    save_infer_path="${save_log}"
                    if [[ ${inference_dir} != "null" ]] && [[ ${inference_dir} != '##' ]]; then ##
                        infer_model_dir="${save_infer_path}/${inference_dir}"
                    else
                        infer_model_dir=${save_infer_path}
                    fi
                    func_inference "${python}" "${inference_py}" "${infer_model_dir}" "${LOG_PATH}" "${train_infer_img_dir}" "${flag_quant}"

                    eval "unset CUDA_VISIBLE_DEVICES"
                fi
            done  # done with:    for trainer in ${trainer_list[*]}; do
        done      # done with:    for autocast in ${autocast_list[*]}; do
    done          # done with:    for gpu in ${gpu_list[*]}; do
fi  # end if [ ${MODE} = "infer" ]; then