// Copyright (c) 2022 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "fastdeploy/backends/paddle/paddle_backend.h"
#include "fastdeploy/utils/path.h"
#include <sstream>

namespace fastdeploy {

void PaddleBackend::BuildOption(const PaddleBackendOption& option) {
  option_ = option;
  if (option.use_gpu) {
    config_.EnableUseGpu(option.gpu_mem_init_size, option.gpu_id);
    if (option.enable_trt) {
#ifdef ENABLE_TRT_BACKEND
      auto precision = paddle_infer::PrecisionType::kFloat32;
      if (option.trt_option.enable_fp16) {
        precision = paddle_infer::PrecisionType::kHalf;
      }
      bool use_static = false;
      if (option.trt_option.serialize_file != "") {
        FDWARNING << "Detect that tensorrt cache file has been set to " << option.trt_option.serialize_file << ", but while enable paddle2trt, please notice that the cache file will save to the directory where paddle model saved." << std::endl;
        use_static = true;
      }
      config_.EnableTensorRtEngine(option.trt_option.max_workspace_size, 32, 3, precision, use_static);
      SetTRTDynamicShapeToConfig(option);
#else
      FDWARNING << "The FastDeploy is not compiled with TensorRT backend, so will fallback to GPU with Paddle Inference Backend." << std::endl;
#endif
    }
  } else {
    config_.DisableGpu();
    if (option.enable_mkldnn) {
      config_.EnableMKLDNN();
      config_.SetMkldnnCacheCapacity(option.mkldnn_cache_size);
    }
  }
  if (!option.enable_log_info) {
    config_.DisableGlogInfo();
  }
  if (!option.delete_pass_names.empty()) {
    auto pass_builder = config_.pass_builder();
    for (int i = 0; i < option.delete_pass_names.size(); i++) {
      FDINFO << "Delete pass : " << option.delete_pass_names[i] << std::endl;
      pass_builder->DeletePass(option.delete_pass_names[i]);
    }
  }
  if (option.cpu_thread_num <= 0) {
    config_.SetCpuMathLibraryNumThreads(8);
  } else {
    config_.SetCpuMathLibraryNumThreads(option.cpu_thread_num);
  }
}

bool PaddleBackend::InitFromPaddle(const std::string& model_file,
                                   const std::string& params_file,
                                   const PaddleBackendOption& option) {
  if (initialized_) {
    FDERROR << "PaddleBackend is already initlized, cannot initialize again."
            << std::endl;
    return false;
  }
  config_.SetModel(model_file, params_file);
  BuildOption(option);

  // The input/output information get from predictor is not right, use PaddleReader instead now
  std::string contents;
  if (!ReadBinaryFromFile(model_file, &contents)) {
    return false;
  }
  auto reader =
      paddle2onnx::PaddleReader(contents.c_str(), contents.size());

  // If it's a quantized model, and use cpu with mkldnn, automaticaly switch to int8 mode
  if (reader.is_quantize_model) {
    if (option.use_gpu) {
      FDWARNING << "The loaded model is a quantized model, while inference on GPU, please use TensorRT backend to get better performance." << std::endl;
      if (option.enable_trt) {
#ifdef ENABLE_TRT_BACKEND
        bool use_static = false;
        if (option.trt_option.serialize_file != "") {
          FDWARNING << "Detect that tensorrt cache file has been set to " << option.trt_option.serialize_file << ", but while enable paddle2trt, please notice that the cache file will save to the directory where paddle model saved." << std::endl;
          use_static = true;
        }
        config_.EnableTensorRtEngine(option.trt_option.max_workspace_size, 32, 3, paddle_infer::PrecisionType::kInt8, use_static, false);
        SetTRTDynamicShapeToConfig(option);
#endif
      }
    }
    if (option.enable_mkldnn) {
      config_.EnableMkldnnInt8();
    } else {
      FDWARNING << "The loaded model is a quantized model, while inference on CPU, please enable MKLDNN to get better performance." << std::endl;
    }
  }

  inputs_desc_.resize(reader.num_inputs);
  for (int i = 0; i < reader.num_inputs; ++i) {
    std::string name(reader.inputs[i].name);
    std::vector<int64_t> shape(
        reader.inputs[i].shape,
        reader.inputs[i].shape + reader.inputs[i].rank);
    inputs_desc_[i].name = name;
    inputs_desc_[i].shape.assign(shape.begin(), shape.end());
    inputs_desc_[i].dtype = ReaderDataTypeToFD(reader.inputs[i].dtype);
  }
  outputs_desc_.resize(reader.num_outputs);
  for (int i = 0; i < reader.num_outputs; ++i) {
    std::string name(reader.outputs[i].name);
    std::vector<int64_t> shape(reader.outputs[i].shape, reader.outputs[i].shape + reader.outputs[i].rank);
    outputs_desc_[i].name = name;
    outputs_desc_[i].shape.assign(shape.begin(), shape.end());
    outputs_desc_[i].dtype = ReaderDataTypeToFD(reader.outputs[i].dtype);
  }
#ifdef ENABLE_TRT_BACKEND
  if (option.collect_shape) {
    // Set the shape info file.
    auto curr_model_dir = GetDirFromPath(model_file);
    std::string shape_range_info = PathJoin(curr_model_dir, "shape_range_info.pbtxt");
    if (!CheckFileExists(shape_range_info)) {
      FDINFO << "Start generating shape range info file." << std::endl;
      paddle_infer::Config analysis_config;
      analysis_config.SetModel(model_file, params_file);
      analysis_config.CollectShapeRangeInfo(shape_range_info);
      auto predictor_tmp = paddle_infer::CreatePredictor(analysis_config);
      std::map<std::string, std::vector<int>> max_shape;
      std::map<std::string, std::vector<int>> min_shape;
      std::map<std::string, std::vector<int>> opt_shape;
      GetDynamicShapeFromOption(option, &max_shape, &min_shape, &opt_shape);
      // Need to run once to get the shape range info file.
      CollectShapeRun(predictor_tmp.get(), max_shape);
      CollectShapeRun(predictor_tmp.get(), min_shape);
      CollectShapeRun(predictor_tmp.get(), opt_shape);
      FDINFO << "Finish generating shape range info file." << std::endl;
    }
    FDINFO << "Start loading shape range info file "<< shape_range_info << " to set TensorRT dynamic shape." << std::endl;
    config_.EnableTunedTensorRtDynamicShape(shape_range_info, false);
  }
#endif
  predictor_ = paddle_infer::CreatePredictor(config_);
  initialized_ = true;
  return true;
}

TensorInfo PaddleBackend::GetInputInfo(int index) {
  FDASSERT(index < NumInputs(),
           "The index: %d should less than the number of inputs: %d.", index,
           NumInputs());
  return inputs_desc_[index];
}

std::vector<TensorInfo> PaddleBackend::GetInputInfos() { return inputs_desc_; }

TensorInfo PaddleBackend::GetOutputInfo(int index) {
  FDASSERT(index < NumOutputs(),
           "The index: %d should less than the number of outputs %d.", index,
           NumOutputs());
  return outputs_desc_[index];
}

std::vector<TensorInfo> PaddleBackend::GetOutputInfos() {
  return outputs_desc_;
}

bool PaddleBackend::Infer(std::vector<FDTensor>& inputs,
                          std::vector<FDTensor>* outputs) {
  if (inputs.size() != inputs_desc_.size()) {
    FDERROR << "[PaddleBackend] Size of inputs(" << inputs.size()
            << ") should keep same with the inputs of this model("
            << inputs_desc_.size() << ")." << std::endl;
    return false;
  }

  for (size_t i = 0; i < inputs.size(); ++i) {
    auto handle = predictor_->GetInputHandle(inputs[i].name);
    ShareTensorFromFDTensor(handle.get(), inputs[i]);
  }

  predictor_->Run();
  outputs->resize(outputs_desc_.size());
  for (size_t i = 0; i < outputs_desc_.size(); ++i) {
    auto handle = predictor_->GetOutputHandle(outputs_desc_[i].name);
    (*outputs)[i].is_pinned_memory = option_.enable_pinned_memory;
    CopyTensorToCpu(handle, &((*outputs)[i]));
  }
  return true;
}

#ifdef ENABLE_TRT_BACKEND
void PaddleBackend::SetTRTDynamicShapeToConfig(const PaddleBackendOption& option) {
    std::map<std::string, std::vector<int>> max_shape;
    std::map<std::string, std::vector<int>> min_shape;
    std::map<std::string, std::vector<int>> opt_shape;
    GetDynamicShapeFromOption(option, &max_shape, &min_shape, &opt_shape);
    FDINFO << "Start setting trt dynamic shape." << std::endl;
    if (min_shape.size() > 0) {
      config_.SetTRTDynamicShapeInfo(min_shape, max_shape, opt_shape);
    }
    FDINFO << "Finish setting trt dynamic shape." << std::endl;
}

void PaddleBackend::GetDynamicShapeFromOption(const PaddleBackendOption& option,
      std::map<std::string, std::vector<int>>* max_shape,
      std::map<std::string, std::vector<int>>* min_shape,
      std::map<std::string, std::vector<int>>* opt_shape) const {
  auto print_shape = [](const std::vector<int>& shape) -> std::string {
    std::ostringstream oss;
    oss << "[";
    for (int i = 0; i < shape.size(); ++i) {
      oss << shape[i];
      if (i < shape.size() - 1) {
        oss << ", ";
      }
    }
    oss << "]";
    return oss.str();
  };
  for (const auto& item : option.trt_option.min_shape) {
    auto max_iter = option.trt_option.max_shape.find(item.first);
    auto opt_iter = option.trt_option.opt_shape.find(item.first);
    FDASSERT(max_iter != option.trt_option.max_shape.end(), "Cannot find %s in TrtBackendOption::min_shape.", item.first.c_str());
    FDASSERT(opt_iter != option.trt_option.opt_shape.end(), "Cannot find %s in TrtBackendOption::opt_shape.", item.first.c_str());
    (*max_shape)[item.first].assign(max_iter->second.begin(), max_iter->second.end());
    (*opt_shape)[item.first].assign(opt_iter->second.begin(), opt_iter->second.end());
    (*min_shape)[item.first].assign(item.second.begin(), item.second.end());
    FDINFO << item.first << ": the max shape = " << print_shape(max_iter->second)
           << ", the min shape = " << print_shape(item.second)
           << ", the opt shape = " << print_shape(opt_iter->second) << std::endl;
  }
}

void PaddleBackend::CollectShapeRun(paddle_infer::Predictor* predictor,
    const std::map<std::string, std::vector<int>>& shape) const {
  auto input_names = predictor->GetInputNames();
  auto input_type = predictor->GetInputTypes();
  for(auto name : input_names) {
    FDASSERT(shape.find(name) != shape.end() && input_type.find(name) != input_type.end(),
      "Paddle Input name [%s] is not one of the trt dynamic shape.", name.c_str());
    auto tensor = predictor->GetInputHandle(name);
    auto shape_value = shape.at(name);
    int shape_num = std::accumulate(shape_value.begin(), shape_value.end(), 1,
                                    std::multiplies<int>());
    tensor->Reshape(shape_value);
    auto dtype = input_type[name];
    switch (dtype) {
      case paddle_infer::DataType::FLOAT32: {
        std::vector<float> input_data(shape_num, 1.0);
        tensor->CopyFromCpu(input_data.data());
        break;
      }
      case paddle_infer::DataType::INT32: {
        std::vector<int> input_data(shape_num, 1);
        tensor->CopyFromCpu(input_data.data());
        break;
      }
      case paddle_infer::DataType::INT64: {
        std::vector<int64_t> input_data(shape_num, 1);
        tensor->CopyFromCpu(input_data.data());
        break;
      }
      default: {
        FDASSERT(false, "Input data Paddle backend only supports FP32/INT32/INT64 currently.");
        break;
      }
    }
  }
  predictor->Run();
}
#endif


}  // namespace fastdeploy