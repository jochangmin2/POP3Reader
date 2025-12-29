package com.xcurenet.pop3reader;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.ApplicationPidFileWriter;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.scheduling.annotation.EnableScheduling;

import java.nio.file.Paths;

@EnableScheduling
@SpringBootApplication
public class Pop3ReaderApplication {

	public final static String PID_FILE = "./bin/application.pid";

	public static void main(String[] args) {
		SpringApplication application = new SpringApplication(Pop3ReaderApplication.class);
		application.setRegisterShutdownHook(false);
		application.addListeners(new ApplicationPidFileWriter(Paths.get(PID_FILE).toFile()));

		ConfigurableApplicationContext ctx = application.run(args);
		Runtime.getRuntime().addShutdownHook(new Thread(ctx::close));
	}

}
