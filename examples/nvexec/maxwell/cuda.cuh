/*
 * Copyright (c) 2022 NVIDIA Corporation
 *
 * Licensed under the Apache License Version 2.0 with LLVM Exceptions
 * (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 *   https://llvm.org/LICENSE.txt
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include "common.cuh"
#include "nvexec/detail/throw_on_cuda_error.cuh"

template <int BlockThreads, class Action>
__launch_bounds__(BlockThreads)
__global__ void kernel(std::size_t cells, Action action) {
  std::size_t cell_id = threadIdx.x + blockIdx.x * BlockThreads;

  if (cell_id < cells) {
    action(cell_id);
  }
}

void run_cuda(float dt, bool write_vtk, std::size_t n_inner_iterations,
              std::size_t n_outer_iterations, grid_t &grid,
              std::string_view method) {
  fields_accessor accessor = grid.accessor();

  constexpr int block_threads = 256;
  const std::size_t cells = accessor.cells;
  const std::size_t grid_blocks = (cells + block_threads - 1) / block_threads;

  time_storage_t time{true};
  std::size_t report_step{};
  auto writer = dump_vtk(write_vtk, report_step, accessor);
  auto initializer = grid_initializer(dt, accessor);
  auto h_updater = update_h(accessor);
  auto e_updater = update_e(time.get(), dt, accessor);

  kernel<block_threads><<<grid_blocks, block_threads>>>(cells, initializer);

  report_performance(grid.cells, n_inner_iterations * n_outer_iterations, method,
                     [&]() {
                         for (; report_step < n_outer_iterations; report_step++) {
                           for (std::size_t compute_step = 0;
                                compute_step < n_inner_iterations;
                                compute_step++) {

                             kernel<block_threads><<<grid_blocks, block_threads>>>(cells, h_updater);
                             kernel<block_threads><<<grid_blocks, block_threads>>>(cells, e_updater);
                           }
                           writer(false);
                         }
                         STDEXEC_DBG_ERR(cudaStreamSynchronize(0));
                     });
}
