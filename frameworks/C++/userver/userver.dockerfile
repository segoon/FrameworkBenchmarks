FROM ghcr.io/userver-framework/ubuntu-22.04-userver-pg AS builder

RUN apt update && \
    apt install -y lsb-release wget software-properties-common gnupg && \
        wget https://apt.llvm.org/llvm.sh && chmod +x llvm.sh && ./llvm.sh 16

WORKDIR /src
RUN git clone https://github.com/userver-framework/userver.git && \
    cd userver && git checkout bdd5e1e03921ff378b062f86a189c3cfa3d66332

COPY userver_benchmark/ ./
RUN mkdir build && cd build && \
    cmake -DUSERVER_IS_THE_ROOT_PROJECT=0 -DUSERVER_FEATURE_CRYPTOPP_BLAKE2=0 \
          -DUSERVER_FEATURE_UTEST=0 \
          -DUSERVER_FEATURE_POSTGRESQL=1 \
          -DUSERVER_FEATURE_ERASE_LOG_WITH_LEVEL=warning \
          -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_CXX_FLAGS="-march=native -fprofile-instr-generate" \
	  -DCMAKE_C_FLAGS="-march=native -fprofile-instr-generate" \
          -DCMAKE_CXX_COMPILER=clang++-16 -DCMAKE_C_COMPILER=clang-16 -DUSERVER_USE_LD=lld-16 \
          -DUSERVER_LTO=0 .. && \
    make -j $(nproc)

FROM builder AS runner
COPY userver_configs/* /app/
COPY --from=builder /src/build/userver_techempower /app/

RUN apt install -y wrk psmisc
RUN service postgresql start && \
    sleep 1 && \
    sudo -u postgres psql -c "ALTER USER postgres with  PASSWORD '12345';" && \
    sudo -u postgres psql -c "CREATE DATABASE tmp;" && \
    /app/userver_techempower -c /app/static_config.yaml & \
    sleep 6 && \
    wrk -d 5 -c 256 --timeout 8 -t 2 "http://localhost:8080/plaintext" && \
    killall userver_techempower && \
    sleep 5

RUN llvm-profdata-16 merge -output=code.profdata default.profraw
RUN cd build && \
    cmake -DCMAKE_CXX_FLAGS="-march=native -fprofile-instr-use=/src/code.profdata" \
	  -DCMAKE_C_FLAGS="-march=native -fprofile-instr-use=/src/code.profdata" \
	  .. && \
    make -j $(nproc)


WORKDIR /app
EXPOSE 8080
RUN set -xe && service postgresql start && \
    sleep 1 && \
    /app/userver_techempower -c /app/static_config.yaml & \
    sleep 12 && \
    wrk -d 5 -c 256 --timeout 8 -t 2 "http://localhost:8080/plaintext"

CMD ./userver_techempower -c ./static_config.yaml

